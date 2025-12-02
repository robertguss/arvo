"""Billing service for business logic."""

from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import Depends, HTTPException, status

from .models import Invoice, StripeCustomer, Subscription, UsageRecord
from .repos import BillingRepository
from .schemas import (
    CheckoutSessionCreate,
    CheckoutSessionResponse,
    PortalSessionCreate,
    PortalSessionResponse,
    SubscriptionCancelRequest,
    UsageReportCreate,
)
from .stripe_client import stripe_client


class BillingService:
    """Service for billing operations."""

    def __init__(self, repo: Annotated[BillingRepository, Depends()]):
        self.repo = repo

    # ============================================================
    # Customer Management
    # ============================================================

    async def get_or_create_customer(
        self, tenant_id: UUID, email: str | None = None, name: str | None = None
    ) -> StripeCustomer:
        """Get existing customer or create a new one."""
        customer = await self.repo.get_customer_by_tenant(tenant_id)

        if customer:
            return customer

        # Create customer in Stripe
        stripe_customer = await stripe_client.create_customer(
            email=email,
            name=name,
            metadata={"tenant_id": str(tenant_id)},
        )

        # Save to database
        customer = StripeCustomer(
            tenant_id=tenant_id,
            stripe_customer_id=stripe_customer.id,
            email=email,
            name=name,
            metadata={"stripe_created": stripe_customer.created},
        )
        return await self.repo.create_customer(customer)

    async def get_customer(self, tenant_id: UUID) -> StripeCustomer | None:
        """Get customer for a tenant."""
        return await self.repo.get_customer_by_tenant(tenant_id)

    # ============================================================
    # Checkout
    # ============================================================

    async def create_checkout_session(
        self,
        tenant_id: UUID,
        data: CheckoutSessionCreate,
        email: str | None = None,
    ) -> CheckoutSessionResponse:
        """Create a Stripe Checkout session."""
        # Get or create customer
        customer = await self.get_or_create_customer(tenant_id, email=email)

        # Create checkout session in Stripe
        session = await stripe_client.create_checkout_session(
            customer_id=customer.stripe_customer_id,
            price_id=data.price_id,
            success_url=data.success_url,
            cancel_url=data.cancel_url,
            mode=data.mode,
            quantity=data.quantity,
            metadata={"tenant_id": str(tenant_id)},
        )

        return CheckoutSessionResponse(session_id=session.id, url=session.url or "")

    # ============================================================
    # Customer Portal
    # ============================================================

    async def create_portal_session(
        self, tenant_id: UUID, data: PortalSessionCreate
    ) -> PortalSessionResponse:
        """Create a Stripe Customer Portal session."""
        customer = await self.repo.get_customer_by_tenant(tenant_id)

        if not customer:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="No billing account found. Please subscribe first.",
            )

        session = await stripe_client.create_portal_session(
            customer_id=customer.stripe_customer_id,
            return_url=data.return_url,
        )

        return PortalSessionResponse(url=session.url)

    # ============================================================
    # Subscriptions
    # ============================================================

    async def get_subscription(self, tenant_id: UUID) -> Subscription | None:
        """Get active subscription for a tenant."""
        return await self.repo.get_active_subscription(tenant_id)

    async def list_subscriptions(
        self, tenant_id: UUID, limit: int = 10, offset: int = 0
    ) -> list[Subscription]:
        """List all subscriptions for a tenant."""
        return await self.repo.list_subscriptions(tenant_id, limit, offset)

    async def cancel_subscription(
        self, tenant_id: UUID, subscription_id: UUID, data: SubscriptionCancelRequest
    ) -> Subscription:
        """Cancel a subscription."""
        subscription = await self.repo.get_subscription(subscription_id, tenant_id)

        if not subscription:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Subscription not found",
            )

        if subscription.status in ["canceled", "incomplete_expired"]:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Subscription is already canceled",
            )

        # Cancel in Stripe
        await stripe_client.cancel_subscription(
            subscription.stripe_subscription_id,
            cancel_immediately=data.cancel_immediately,
        )

        # Update local record
        update_data = {
            "cancel_at_period_end": not data.cancel_immediately,
            "canceled_at": datetime.now(UTC),
        }
        if data.cancel_immediately:
            update_data["status"] = "canceled"

        return await self.repo.update_subscription(subscription, update_data)

    # ============================================================
    # Usage / Metered Billing
    # ============================================================

    async def report_usage(
        self, tenant_id: UUID, data: UsageReportCreate
    ) -> UsageRecord:
        """Report metered usage for a subscription."""
        # Check idempotency
        if data.idempotency_key:
            existing = await self.repo.get_usage_by_idempotency_key(
                data.idempotency_key
            )
            if existing:
                return existing

        # Get subscription
        subscription = await self.repo.get_subscription(data.subscription_id, tenant_id)

        if not subscription:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Subscription not found",
            )

        if subscription.status not in ["active", "trialing"]:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Subscription is not active",
            )

        # Get subscription from Stripe to get the subscription item
        stripe_sub = await stripe_client.get_subscription(
            subscription.stripe_subscription_id
        )

        if not stripe_sub.items.data:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="No subscription items found",
            )

        subscription_item_id = stripe_sub.items.data[0].id

        # Report to Stripe
        timestamp = data.timestamp or datetime.now(UTC)
        await stripe_client.create_usage_record(
            subscription_item_id=subscription_item_id,
            quantity=data.quantity,
            timestamp=int(timestamp.timestamp()),
            action=data.action,
            idempotency_key=data.idempotency_key,
        )

        # Save locally
        usage = UsageRecord(
            tenant_id=tenant_id,
            subscription_id=subscription.id,
            quantity=data.quantity,
            action=data.action,
            timestamp=timestamp,
            idempotency_key=data.idempotency_key,
        )
        return await self.repo.create_usage_record(usage)

    # ============================================================
    # Invoices
    # ============================================================

    async def list_invoices(
        self, tenant_id: UUID, page: int = 1, page_size: int = 10
    ) -> tuple[list[Invoice], int]:
        """List invoices for a tenant."""
        offset = (page - 1) * page_size
        return await self.repo.list_invoices(tenant_id, page_size, offset)
