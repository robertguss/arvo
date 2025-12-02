"""Tests for audit middleware context management.

Verifies that the ContextVar-based audit context provides proper
isolation between concurrent async requests.
"""

import asyncio
from uuid import uuid4

import pytest

from app.core.audit.middleware import (
    clear_audit_context,
    get_audit_context,
    set_audit_context,
)


class TestAuditContextBasic:
    """Basic tests for audit context functions."""

    def test_get_context_returns_empty_dict_when_not_set(self):
        """Test that get_audit_context returns empty dict when not set."""
        clear_audit_context()
        context = get_audit_context()
        assert context == {}

    def test_set_and_get_context(self):
        """Test setting and getting audit context."""
        tenant_id = uuid4()
        user_id = uuid4()

        set_audit_context(
            tenant_id=tenant_id,
            user_id=user_id,
            request_id="req-123",
            ip_address="192.168.1.1",
            user_agent="Test Agent",
        )

        context = get_audit_context()

        assert context["tenant_id"] == tenant_id
        assert context["user_id"] == user_id
        assert context["request_id"] == "req-123"
        assert context["ip_address"] == "192.168.1.1"
        assert context["user_agent"] == "Test Agent"

        # Cleanup
        clear_audit_context()

    def test_clear_context(self):
        """Test clearing audit context."""
        set_audit_context(
            tenant_id=uuid4(),
            user_id=uuid4(),
            request_id="req-456",
        )

        clear_audit_context()
        context = get_audit_context()

        assert context == {}

    def test_get_context_returns_copy(self):
        """Test that get_audit_context returns a copy, not the original."""
        tenant_id = uuid4()
        set_audit_context(tenant_id=tenant_id)

        context1 = get_audit_context()
        context1["modified"] = True

        context2 = get_audit_context()
        assert "modified" not in context2
        assert context2["tenant_id"] == tenant_id

        # Cleanup
        clear_audit_context()

    def test_set_context_overwrites_previous(self):
        """Test that set_audit_context completely replaces previous context."""
        tenant_id1 = uuid4()
        tenant_id2 = uuid4()

        set_audit_context(
            tenant_id=tenant_id1,
            user_id=uuid4(),
            request_id="first-request",
        )

        set_audit_context(
            tenant_id=tenant_id2,
            request_id="second-request",
        )

        context = get_audit_context()
        assert context["tenant_id"] == tenant_id2
        assert context["request_id"] == "second-request"
        # user_id should be None in new context, not carried over
        assert context["user_id"] is None

        # Cleanup
        clear_audit_context()


class TestAuditContextAsyncIsolation:
    """Tests verifying async context isolation."""

    @pytest.mark.asyncio
    async def test_context_isolated_between_tasks(self):
        """Test that context is isolated between concurrent async tasks."""
        tenant1 = uuid4()
        tenant2 = uuid4()
        results: dict[str, dict] = {}

        async def task1():
            set_audit_context(tenant_id=tenant1, request_id="task1")
            await asyncio.sleep(0.01)  # Yield control
            results["task1"] = get_audit_context()
            clear_audit_context()

        async def task2():
            set_audit_context(tenant_id=tenant2, request_id="task2")
            await asyncio.sleep(0.01)  # Yield control
            results["task2"] = get_audit_context()
            clear_audit_context()

        # Run both tasks concurrently
        await asyncio.gather(task1(), task2())

        # Each task should have its own context
        assert results["task1"]["tenant_id"] == tenant1
        assert results["task1"]["request_id"] == "task1"

        assert results["task2"]["tenant_id"] == tenant2
        assert results["task2"]["request_id"] == "task2"

    @pytest.mark.asyncio
    async def test_child_task_inherits_but_changes_dont_propagate_back(self):
        """Test that child tasks inherit context but changes don't affect parent."""
        tenant_id = uuid4()
        new_tenant_id = uuid4()

        async def child_task():
            # Child sees parent's context
            ctx = get_audit_context()
            assert ctx["tenant_id"] == tenant_id

            # Child modifies its context
            set_audit_context(tenant_id=new_tenant_id, request_id="child-request")
            return get_audit_context()

        set_audit_context(tenant_id=tenant_id, request_id="parent-request")

        # Run child task
        child_ctx = await asyncio.create_task(child_task())

        # Child saw its own modified context
        assert child_ctx["tenant_id"] == new_tenant_id
        assert child_ctx["request_id"] == "child-request"

        # Parent context remains unchanged
        parent_ctx = get_audit_context()
        assert parent_ctx["tenant_id"] == tenant_id
        assert parent_ctx["request_id"] == "parent-request"

        clear_audit_context()

    @pytest.mark.asyncio
    async def test_nested_tasks_inherit_context(self):
        """Test that nested tasks inherit the parent's context."""
        tenant_id = uuid4()
        inner_context = {}

        async def outer_task():
            set_audit_context(tenant_id=tenant_id, request_id="outer")

            async def inner_task():
                nonlocal inner_context
                inner_context = get_audit_context()

            # Inner task runs in the same context
            await inner_task()

            clear_audit_context()

        await outer_task()

        # Inner task should have seen the outer task's context
        assert inner_context["tenant_id"] == tenant_id
        assert inner_context["request_id"] == "outer"

    @pytest.mark.asyncio
    async def test_many_concurrent_requests_isolation(self):
        """Stress test: verify isolation with many concurrent requests."""
        num_tasks = 50
        results: dict[int, dict] = {}

        async def simulated_request(task_id: int):
            tenant_id = uuid4()
            set_audit_context(
                tenant_id=tenant_id,
                request_id=f"request-{task_id}",
            )
            # Simulate some async work with random delays
            await asyncio.sleep(0.001 * (task_id % 5))
            context = get_audit_context()
            results[task_id] = {
                "expected_tenant": tenant_id,
                "actual_tenant": context.get("tenant_id"),
                "expected_request": f"request-{task_id}",
                "actual_request": context.get("request_id"),
            }
            clear_audit_context()

        # Run many tasks concurrently
        await asyncio.gather(*[simulated_request(i) for i in range(num_tasks)])

        # Verify each task saw its own context
        for task_id, result in results.items():
            assert (
                result["expected_tenant"] == result["actual_tenant"]
            ), f"Task {task_id} saw wrong tenant"
            assert (
                result["expected_request"] == result["actual_request"]
            ), f"Task {task_id} saw wrong request_id"
