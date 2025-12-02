"""Billing Pydantic schemas for request/response validation."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


# ============================================================
# Checkout
# ============================================================

class CheckoutSessionCreate(BaseModel):
    """Request to create a Stripe Checkout session."""

    price_id: str = Field(..., description="Stripe Price ID")
    success_url: str = Field(..., description="URL to redirect after successful payment")
    cancel_url: str = Field(..., description="URL to redirect if checkout is cancelled")
    mode: str = Field(
        "subscription", description="Checkout mode: subscription or payment"
    )
    quantity: int = Field(1, ge=1, description="Quantity of the price")


class CheckoutSessionResponse(BaseModel):
    """Response with Checkout session details."""

    session_id: str
    url: str


# ============================================================
# Customer Portal
# ============================================================

class PortalSessionCreate(BaseModel):
    """Request to create a Stripe Customer Portal session."""

    return_url: str = Field(..., description="URL to return to after portal session")


class PortalSessionResponse(BaseModel):
    """Response with Customer Portal session details."""

    url: str


# ============================================================
# Subscription
# ============================================================

class SubscriptionResponse(BaseModel):
    """Subscription details response."""

    id: UUID
    stripe_subscription_id: str
    stripe_price_id: str
    status: str
    current_period_start: datetime | None
    current_period_end: datetime | None
    cancel_at_period_end: bool
    canceled_at: datetime | None
    trial_start: datetime | None
    trial_end: datetime | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class SubscriptionCancelRequest(BaseModel):
    """Request to cancel a subscription."""

    cancel_immediately: bool = Field(
        False, description="Cancel immediately instead of at period end"
    )


# ============================================================
# Usage
# ============================================================

class UsageReportCreate(BaseModel):
    """Request to report metered usage."""

    subscription_id: UUID = Field(..., description="Subscription ID")
    quantity: int = Field(..., ge=1, description="Usage quantity to report")
    timestamp: datetime | None = Field(
        None, description="Timestamp for the usage (defaults to now)"
    )
    action: str = Field(
        "increment", description="Action: increment or set"
    )
    idempotency_key: str | None = Field(
        None, description="Idempotency key to prevent duplicate reports"
    )


class UsageReportResponse(BaseModel):
    """Response after reporting usage."""

    id: UUID
    quantity: int
    timestamp: datetime
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ============================================================
# Invoice
# ============================================================

class InvoiceResponse(BaseModel):
    """Invoice details response."""

    id: UUID
    stripe_invoice_id: str
    status: str
    amount_due: int
    amount_paid: int
    amount_remaining: int
    currency: str
    hosted_invoice_url: str | None
    invoice_pdf: str | None
    due_date: datetime | None
    paid_at: datetime | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class InvoiceListResponse(BaseModel):
    """Paginated list of invoices."""

    items: list[InvoiceResponse]
    total: int
    page: int
    page_size: int


# ============================================================
# Customer
# ============================================================

class CustomerResponse(BaseModel):
    """Stripe customer details response."""

    id: UUID
    stripe_customer_id: str
    email: str | None
    name: str | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)

