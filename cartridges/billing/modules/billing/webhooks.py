"""Stripe webhook handlers."""

import logging
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
import stripe

from app.config import settings
from .models import StripeCustomer, Subscription, Invoice
from .repos import BillingRepository
from .stripe_client import StripeClient

logger = logging.getLogger(__name__)

webhook_router = APIRouter()


async def get_repo() -> BillingRepository:
    """Get billing repository for webhooks."""
    from app.core.database import get_db

    async for session in get_db():
        return BillingRepository(session)
    raise RuntimeError("Could not get database session")


@webhook_router.post(
    "/webhooks",
    status_code=status.HTTP_200_OK,
    summary="Stripe webhook endpoint",
    description="Receives and processes Stripe webhook events.",
    include_in_schema=False,  # Hide from OpenAPI docs
)
async def stripe_webhook(
    request: Request,
    stripe_signature: Annotated[str, Header(alias="Stripe-Signature")],
) -> dict[str, str]:
    """Handle Stripe webhook events."""
    payload = await request.body()

    # Verify webhook signature
    try:
        event = StripeClient.construct_webhook_event(
            payload=payload,
            sig_header=stripe_signature,
            webhook_secret=settings.stripe_webhook_secret or "",
        )
    except ValueError as e:
        logger.error(f"Invalid payload: {e}")
        raise HTTPException(status_code=400, detail="Invalid payload")
    except stripe.SignatureVerificationError as e:
        logger.error(f"Invalid signature: {e}")
        raise HTTPException(status_code=400, detail="Invalid signature")

    # Get repository
    repo = await get_repo()

    # Handle event types
    event_type = event.type
    event_data = event.data.object

    logger.info(f"Received Stripe event: {event_type}")

    try:
        if event_type == "checkout.session.completed":
            await handle_checkout_completed(repo, event_data)

        elif event_type == "customer.subscription.created":
            await handle_subscription_created(repo, event_data)

        elif event_type == "customer.subscription.updated":
            await handle_subscription_updated(repo, event_data)

        elif event_type == "customer.subscription.deleted":
            await handle_subscription_deleted(repo, event_data)

        elif event_type == "invoice.paid":
            await handle_invoice_paid(repo, event_data)

        elif event_type == "invoice.payment_failed":
            await handle_invoice_payment_failed(repo, event_data)

        elif event_type == "invoice.created":
            await handle_invoice_created(repo, event_data)

        else:
            logger.info(f"Unhandled event type: {event_type}")

    except Exception as e:
        logger.exception(f"Error handling webhook {event_type}: {e}")
        # Return 200 to prevent Stripe from retrying
        # Log the error for investigation

    return {"status": "received"}


# ============================================================
# Checkout Handlers
# ============================================================


async def handle_checkout_completed(
    repo: BillingRepository, session: stripe.checkout.Session
) -> None:
    """Handle checkout.session.completed event."""
    logger.info(f"Checkout completed: {session.id}")

    # The subscription will be created via customer.subscription.created
    # This handler can be used for additional logic like:
    # - Sending welcome emails
    # - Provisioning resources
    # - Analytics tracking


# ============================================================
# Subscription Handlers
# ============================================================


async def handle_subscription_created(
    repo: BillingRepository, sub: stripe.Subscription
) -> None:
    """Handle customer.subscription.created event."""
    logger.info(f"Subscription created: {sub.id}")

    # Get or create customer record
    customer = await repo.get_customer_by_stripe_id(sub.customer)  # type: ignore
    if not customer:
        logger.warning(f"Customer not found for subscription: {sub.customer}")
        return

    # Check if subscription already exists
    existing = await repo.get_subscription_by_stripe_id(sub.id)
    if existing:
        logger.info(f"Subscription already exists: {sub.id}")
        return

    # Create subscription record
    subscription = Subscription(
        tenant_id=customer.tenant_id,
        customer_id=customer.id,
        stripe_subscription_id=sub.id,
        stripe_price_id=sub.items.data[0].price.id if sub.items.data else "",
        status=sub.status,
        current_period_start=datetime.fromtimestamp(
            sub.current_period_start, tz=timezone.utc
        ),
        current_period_end=datetime.fromtimestamp(
            sub.current_period_end, tz=timezone.utc
        ),
        cancel_at_period_end=sub.cancel_at_period_end,
        canceled_at=datetime.fromtimestamp(sub.canceled_at, tz=timezone.utc)
        if sub.canceled_at
        else None,
        trial_start=datetime.fromtimestamp(sub.trial_start, tz=timezone.utc)
        if sub.trial_start
        else None,
        trial_end=datetime.fromtimestamp(sub.trial_end, tz=timezone.utc)
        if sub.trial_end
        else None,
    )
    await repo.create_subscription(subscription)


async def handle_subscription_updated(
    repo: BillingRepository, sub: stripe.Subscription
) -> None:
    """Handle customer.subscription.updated event."""
    logger.info(f"Subscription updated: {sub.id}")

    subscription = await repo.get_subscription_by_stripe_id(sub.id)
    if not subscription:
        logger.warning(f"Subscription not found: {sub.id}")
        return

    # Update subscription record
    update_data = {
        "status": sub.status,
        "current_period_start": datetime.fromtimestamp(
            sub.current_period_start, tz=timezone.utc
        ),
        "current_period_end": datetime.fromtimestamp(
            sub.current_period_end, tz=timezone.utc
        ),
        "cancel_at_period_end": sub.cancel_at_period_end,
        "canceled_at": datetime.fromtimestamp(sub.canceled_at, tz=timezone.utc)
        if sub.canceled_at
        else None,
    }
    await repo.update_subscription(subscription, update_data)


async def handle_subscription_deleted(
    repo: BillingRepository, sub: stripe.Subscription
) -> None:
    """Handle customer.subscription.deleted event."""
    logger.info(f"Subscription deleted: {sub.id}")

    subscription = await repo.get_subscription_by_stripe_id(sub.id)
    if not subscription:
        logger.warning(f"Subscription not found: {sub.id}")
        return

    # Mark as canceled
    await repo.update_subscription(
        subscription,
        {
            "status": "canceled",
            "canceled_at": datetime.now(timezone.utc),
        },
    )


# ============================================================
# Invoice Handlers
# ============================================================


async def handle_invoice_created(
    repo: BillingRepository, inv: stripe.Invoice
) -> None:
    """Handle invoice.created event."""
    logger.info(f"Invoice created: {inv.id}")

    # Get customer
    customer = await repo.get_customer_by_stripe_id(inv.customer)  # type: ignore
    if not customer:
        logger.warning(f"Customer not found for invoice: {inv.customer}")
        return

    # Check if invoice already exists
    existing = await repo.get_invoice_by_stripe_id(inv.id)
    if existing:
        return

    # Create invoice record
    invoice = Invoice(
        tenant_id=customer.tenant_id,
        customer_id=customer.id,
        stripe_invoice_id=inv.id,
        status=inv.status or "draft",
        amount_due=inv.amount_due,
        amount_paid=inv.amount_paid,
        amount_remaining=inv.amount_remaining,
        currency=inv.currency,
        hosted_invoice_url=inv.hosted_invoice_url,
        invoice_pdf=inv.invoice_pdf,
        due_date=datetime.fromtimestamp(inv.due_date, tz=timezone.utc)
        if inv.due_date
        else None,
    )
    await repo.create_invoice(invoice)


async def handle_invoice_paid(repo: BillingRepository, inv: stripe.Invoice) -> None:
    """Handle invoice.paid event."""
    logger.info(f"Invoice paid: {inv.id}")

    invoice = await repo.get_invoice_by_stripe_id(inv.id)
    if not invoice:
        logger.warning(f"Invoice not found: {inv.id}")
        return

    await repo.update_invoice(
        invoice,
        {
            "status": "paid",
            "amount_paid": inv.amount_paid,
            "amount_remaining": inv.amount_remaining,
            "paid_at": datetime.now(timezone.utc),
        },
    )


async def handle_invoice_payment_failed(
    repo: BillingRepository, inv: stripe.Invoice
) -> None:
    """Handle invoice.payment_failed event."""
    logger.info(f"Invoice payment failed: {inv.id}")

    invoice = await repo.get_invoice_by_stripe_id(inv.id)
    if not invoice:
        logger.warning(f"Invoice not found: {inv.id}")
        return

    await repo.update_invoice(
        invoice,
        {
            "status": "open",  # or "uncollectible" depending on settings
        },
    )

    # TODO: Trigger notification to tenant about failed payment

