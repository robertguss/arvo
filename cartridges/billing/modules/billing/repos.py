"""Billing repository for database operations."""

from typing import Annotated
from uuid import UUID

from fastapi import Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from .models import StripeCustomer, Subscription, Invoice, UsageRecord


class BillingRepository:
    """Repository for billing data access."""

    def __init__(self, session: Annotated[AsyncSession, Depends(get_db)]):
        self.session = session

    # ============================================================
    # Customer
    # ============================================================

    async def get_customer_by_tenant(self, tenant_id: UUID) -> StripeCustomer | None:
        """Get Stripe customer for a tenant."""
        result = await self.session.execute(
            select(StripeCustomer).where(StripeCustomer.tenant_id == tenant_id)
        )
        return result.scalar_one_or_none()

    async def get_customer_by_stripe_id(
        self, stripe_customer_id: str
    ) -> StripeCustomer | None:
        """Get customer by Stripe customer ID."""
        result = await self.session.execute(
            select(StripeCustomer).where(
                StripeCustomer.stripe_customer_id == stripe_customer_id
            )
        )
        return result.scalar_one_or_none()

    async def create_customer(self, customer: StripeCustomer) -> StripeCustomer:
        """Create a new Stripe customer record."""
        self.session.add(customer)
        await self.session.flush()
        await self.session.refresh(customer)
        return customer

    async def update_customer(
        self, customer: StripeCustomer, data: dict
    ) -> StripeCustomer:
        """Update a Stripe customer record."""
        for key, value in data.items():
            if hasattr(customer, key):
                setattr(customer, key, value)
        await self.session.flush()
        await self.session.refresh(customer)
        return customer

    # ============================================================
    # Subscription
    # ============================================================

    async def get_subscription(
        self, subscription_id: UUID, tenant_id: UUID
    ) -> Subscription | None:
        """Get a subscription by ID."""
        result = await self.session.execute(
            select(Subscription)
            .where(Subscription.id == subscription_id)
            .where(Subscription.tenant_id == tenant_id)
        )
        return result.scalar_one_or_none()

    async def get_subscription_by_stripe_id(
        self, stripe_subscription_id: str
    ) -> Subscription | None:
        """Get subscription by Stripe subscription ID."""
        result = await self.session.execute(
            select(Subscription).where(
                Subscription.stripe_subscription_id == stripe_subscription_id
            )
        )
        return result.scalar_one_or_none()

    async def get_active_subscription(self, tenant_id: UUID) -> Subscription | None:
        """Get the active subscription for a tenant."""
        result = await self.session.execute(
            select(Subscription)
            .where(Subscription.tenant_id == tenant_id)
            .where(Subscription.status.in_(["active", "trialing"]))
        )
        return result.scalar_one_or_none()

    async def list_subscriptions(
        self, tenant_id: UUID, limit: int = 10, offset: int = 0
    ) -> list[Subscription]:
        """List subscriptions for a tenant."""
        result = await self.session.execute(
            select(Subscription)
            .where(Subscription.tenant_id == tenant_id)
            .order_by(Subscription.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        return list(result.scalars().all())

    async def create_subscription(self, subscription: Subscription) -> Subscription:
        """Create a new subscription record."""
        self.session.add(subscription)
        await self.session.flush()
        await self.session.refresh(subscription)
        return subscription

    async def update_subscription(
        self, subscription: Subscription, data: dict
    ) -> Subscription:
        """Update a subscription record."""
        for key, value in data.items():
            if hasattr(subscription, key):
                setattr(subscription, key, value)
        await self.session.flush()
        await self.session.refresh(subscription)
        return subscription

    # ============================================================
    # Invoice
    # ============================================================

    async def get_invoice_by_stripe_id(self, stripe_invoice_id: str) -> Invoice | None:
        """Get invoice by Stripe invoice ID."""
        result = await self.session.execute(
            select(Invoice).where(Invoice.stripe_invoice_id == stripe_invoice_id)
        )
        return result.scalar_one_or_none()

    async def list_invoices(
        self, tenant_id: UUID, limit: int = 10, offset: int = 0
    ) -> tuple[list[Invoice], int]:
        """List invoices for a tenant with total count."""
        # Get total count
        count_result = await self.session.execute(
            select(Invoice).where(Invoice.tenant_id == tenant_id)
        )
        total = len(list(count_result.scalars().all()))

        # Get paginated results
        result = await self.session.execute(
            select(Invoice)
            .where(Invoice.tenant_id == tenant_id)
            .order_by(Invoice.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        return list(result.scalars().all()), total

    async def create_invoice(self, invoice: Invoice) -> Invoice:
        """Create a new invoice record."""
        self.session.add(invoice)
        await self.session.flush()
        await self.session.refresh(invoice)
        return invoice

    async def update_invoice(self, invoice: Invoice, data: dict) -> Invoice:
        """Update an invoice record."""
        for key, value in data.items():
            if hasattr(invoice, key):
                setattr(invoice, key, value)
        await self.session.flush()
        await self.session.refresh(invoice)
        return invoice

    # ============================================================
    # Usage
    # ============================================================

    async def create_usage_record(self, usage: UsageRecord) -> UsageRecord:
        """Create a new usage record."""
        self.session.add(usage)
        await self.session.flush()
        await self.session.refresh(usage)
        return usage

    async def get_usage_by_idempotency_key(
        self, idempotency_key: str
    ) -> UsageRecord | None:
        """Get usage record by idempotency key."""
        result = await self.session.execute(
            select(UsageRecord).where(UsageRecord.idempotency_key == idempotency_key)
        )
        return result.scalar_one_or_none()

