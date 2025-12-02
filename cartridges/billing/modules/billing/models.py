"""Billing database models."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base, TenantMixin, TimestampMixin, UUIDMixin


class StripeCustomer(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Links a tenant to a Stripe customer."""

    __tablename__ = "stripe_customers"

    stripe_customer_id: Mapped[str] = mapped_column(
        String(255), unique=True, nullable=False, index=True
    )
    email: Mapped[str | None] = mapped_column(String(255))
    name: Mapped[str | None] = mapped_column(String(255))

    # Metadata from Stripe
    metadata: Mapped[dict] = mapped_column(JSONB, default=dict)

    # Relationships
    subscriptions: Mapped[list["Subscription"]] = relationship(
        back_populates="customer", cascade="all, delete-orphan"
    )
    invoices: Mapped[list["Invoice"]] = relationship(
        back_populates="customer", cascade="all, delete-orphan"
    )


class Subscription(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Represents a Stripe subscription."""

    __tablename__ = "subscriptions"

    customer_id: Mapped[UUID] = mapped_column(
        ForeignKey("stripe_customers.id", ondelete="CASCADE"), nullable=False
    )
    stripe_subscription_id: Mapped[str] = mapped_column(
        String(255), unique=True, nullable=False, index=True
    )
    stripe_price_id: Mapped[str] = mapped_column(String(255), nullable=False)

    # Status
    status: Mapped[str] = mapped_column(
        String(50), nullable=False, default="incomplete"
    )  # active, past_due, canceled, incomplete, etc.

    # Billing period
    current_period_start: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )
    current_period_end: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Cancellation
    cancel_at_period_end: Mapped[bool] = mapped_column(Boolean, default=False)
    canceled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Trial
    trial_start: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    trial_end: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Metadata
    metadata: Mapped[dict] = mapped_column(JSONB, default=dict)

    # Relationships
    customer: Mapped["StripeCustomer"] = relationship(back_populates="subscriptions")


class Invoice(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Represents a Stripe invoice."""

    __tablename__ = "invoices"

    customer_id: Mapped[UUID] = mapped_column(
        ForeignKey("stripe_customers.id", ondelete="CASCADE"), nullable=False
    )
    stripe_invoice_id: Mapped[str] = mapped_column(
        String(255), unique=True, nullable=False, index=True
    )

    # Status
    status: Mapped[str] = mapped_column(
        String(50), nullable=False, default="draft"
    )  # draft, open, paid, uncollectible, void

    # Amounts (stored in cents)  # noqa: ERA001
    amount_due: Mapped[int] = mapped_column(Integer, default=0)
    amount_paid: Mapped[int] = mapped_column(Integer, default=0)
    amount_remaining: Mapped[int] = mapped_column(Integer, default=0)
    currency: Mapped[str] = mapped_column(String(3), default="usd")

    # URLs
    hosted_invoice_url: Mapped[str | None] = mapped_column(String(500))
    invoice_pdf: Mapped[str | None] = mapped_column(String(500))

    # Dates
    due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Metadata
    metadata: Mapped[dict] = mapped_column(JSONB, default=dict)

    # Relationships
    customer: Mapped["StripeCustomer"] = relationship(back_populates="invoices")


class UsageRecord(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Tracks metered usage for billing."""

    __tablename__ = "usage_records"

    subscription_id: Mapped[UUID] = mapped_column(
        ForeignKey("subscriptions.id", ondelete="CASCADE"), nullable=False
    )
    stripe_usage_record_id: Mapped[str | None] = mapped_column(
        String(255), unique=True, index=True
    )

    # Usage data
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    action: Mapped[str] = mapped_column(
        String(50), default="increment"
    )  # increment or set

    # Timestamp for the usage
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    # Optional idempotency key
    idempotency_key: Mapped[str | None] = mapped_column(String(255), unique=True)
