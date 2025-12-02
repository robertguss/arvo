"""Stripe client wrapper for async operations."""

import asyncio
import logging
from collections.abc import Callable
from functools import wraps
from typing import Any, ParamSpec, TypeVar

import stripe

from app.config import settings


logger = logging.getLogger(__name__)

# Type variables for generic wrapper
P = ParamSpec("P")
R = TypeVar("R")


def configure_stripe() -> None:
    """Configure the Stripe SDK with API key."""
    stripe.api_key = settings.stripe_secret_key


def async_stripe(func: Callable[P, R]) -> Callable[P, R]:
    """Decorator to run Stripe SDK calls in a thread pool."""

    @wraps(func)
    async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        return await asyncio.to_thread(func, *args, **kwargs)

    return wrapper  # type: ignore


class StripeClient:
    """Async wrapper for Stripe API operations."""

    def __init__(self) -> None:
        """Initialize the Stripe client."""
        configure_stripe()

    # ============================================================
    # Customers
    # ============================================================

    async def create_customer(
        self,
        email: str | None = None,
        name: str | None = None,
        metadata: dict[str, str] | None = None,
    ) -> stripe.Customer:
        """Create a new Stripe customer."""
        return await asyncio.to_thread(
            stripe.Customer.create,
            email=email,
            name=name,
            metadata=metadata or {},
        )

    async def get_customer(self, customer_id: str) -> stripe.Customer:
        """Retrieve a Stripe customer."""
        return await asyncio.to_thread(stripe.Customer.retrieve, customer_id)

    async def update_customer(self, customer_id: str, **kwargs: Any) -> stripe.Customer:
        """Update a Stripe customer."""
        return await asyncio.to_thread(stripe.Customer.modify, customer_id, **kwargs)

    # ============================================================
    # Checkout Sessions
    # ============================================================

    async def create_checkout_session(
        self,
        customer_id: str,
        price_id: str,
        success_url: str,
        cancel_url: str,
        mode: str = "subscription",
        quantity: int = 1,
        metadata: dict[str, str] | None = None,
    ) -> stripe.checkout.Session:
        """Create a Stripe Checkout session."""
        return await asyncio.to_thread(
            stripe.checkout.Session.create,
            customer=customer_id,
            line_items=[{"price": price_id, "quantity": quantity}],
            mode=mode,
            success_url=success_url,
            cancel_url=cancel_url,
            metadata=metadata or {},
        )

    # ============================================================
    # Customer Portal
    # ============================================================

    async def create_portal_session(
        self, customer_id: str, return_url: str
    ) -> stripe.billing_portal.Session:
        """Create a Stripe Customer Portal session."""
        return await asyncio.to_thread(
            stripe.billing_portal.Session.create,
            customer=customer_id,
            return_url=return_url,
        )

    # ============================================================
    # Subscriptions
    # ============================================================

    async def get_subscription(self, subscription_id: str) -> stripe.Subscription:
        """Retrieve a Stripe subscription."""
        return await asyncio.to_thread(stripe.Subscription.retrieve, subscription_id)

    async def cancel_subscription(
        self, subscription_id: str, cancel_immediately: bool = False
    ) -> stripe.Subscription:
        """Cancel a Stripe subscription."""
        if cancel_immediately:
            return await asyncio.to_thread(stripe.Subscription.cancel, subscription_id)
        else:
            return await asyncio.to_thread(
                stripe.Subscription.modify,
                subscription_id,
                cancel_at_period_end=True,
            )

    async def update_subscription(
        self, subscription_id: str, **kwargs: Any
    ) -> stripe.Subscription:
        """Update a Stripe subscription."""
        return await asyncio.to_thread(
            stripe.Subscription.modify, subscription_id, **kwargs
        )

    # ============================================================
    # Usage Records (Metered Billing)
    # ============================================================

    async def create_usage_record(
        self,
        subscription_item_id: str,
        quantity: int,
        timestamp: int | None = None,
        action: str = "increment",
        idempotency_key: str | None = None,
    ) -> stripe.UsageRecord:
        """Create a usage record for metered billing."""
        params: dict[str, Any] = {
            "quantity": quantity,
            "action": action,
        }
        if timestamp:
            params["timestamp"] = timestamp

        kwargs: dict[str, Any] = {}
        if idempotency_key:
            kwargs["idempotency_key"] = idempotency_key

        return await asyncio.to_thread(
            stripe.SubscriptionItem.create_usage_record,
            subscription_item_id,
            **params,
            **kwargs,
        )

    # ============================================================
    # Invoices
    # ============================================================

    async def get_invoice(self, invoice_id: str) -> stripe.Invoice:
        """Retrieve a Stripe invoice."""
        return await asyncio.to_thread(stripe.Invoice.retrieve, invoice_id)

    async def list_invoices(
        self, customer_id: str, limit: int = 10
    ) -> list[stripe.Invoice]:
        """List invoices for a customer."""
        result = await asyncio.to_thread(
            stripe.Invoice.list, customer=customer_id, limit=limit
        )
        return list(result.data)

    # ============================================================
    # Webhooks
    # ============================================================

    @staticmethod
    def construct_webhook_event(
        payload: bytes, sig_header: str, webhook_secret: str
    ) -> stripe.Event:
        """Construct and verify a webhook event."""
        return stripe.Webhook.construct_event(payload, sig_header, webhook_secret)


# Global client instance
stripe_client = StripeClient()
