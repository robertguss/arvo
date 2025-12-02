"""Billing API routes."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query, status

from app.core.auth import get_current_user
from app.modules.users.models import User

from .schemas import (
    CheckoutSessionCreate,
    CheckoutSessionResponse,
    CustomerResponse,
    InvoiceListResponse,
    InvoiceResponse,
    PortalSessionCreate,
    PortalSessionResponse,
    SubscriptionCancelRequest,
    SubscriptionResponse,
    UsageReportCreate,
    UsageReportResponse,
)
from .services import BillingService
from .webhooks import webhook_router

router = APIRouter(prefix="/billing", tags=["billing"])

# Include webhook router (no auth required for Stripe webhooks)
router.include_router(webhook_router)


# ============================================================
# Checkout
# ============================================================


@router.post(
    "/checkout",
    response_model=CheckoutSessionResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create checkout session",
    description="Create a Stripe Checkout session for subscription signup.",
)
async def create_checkout_session(
    data: CheckoutSessionCreate,
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> CheckoutSessionResponse:
    """Create a Stripe Checkout session."""
    return await service.create_checkout_session(
        tenant_id=current_user.tenant_id,
        data=data,
        email=current_user.email,
    )


# ============================================================
# Customer Portal
# ============================================================


@router.post(
    "/portal",
    response_model=PortalSessionResponse,
    summary="Create portal session",
    description="Create a Stripe Customer Portal session for self-service billing management.",
)
async def create_portal_session(
    data: PortalSessionCreate,
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> PortalSessionResponse:
    """Create a Stripe Customer Portal session."""
    return await service.create_portal_session(
        tenant_id=current_user.tenant_id,
        data=data,
    )


# ============================================================
# Customer
# ============================================================


@router.get(
    "/customer",
    response_model=CustomerResponse | None,
    summary="Get billing customer",
    description="Get the billing customer for the current tenant.",
)
async def get_customer(
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> CustomerResponse | None:
    """Get the billing customer for the current tenant."""
    customer = await service.get_customer(current_user.tenant_id)
    if customer:
        return CustomerResponse.model_validate(customer)
    return None


# ============================================================
# Subscriptions
# ============================================================


@router.get(
    "/subscription",
    response_model=SubscriptionResponse | None,
    summary="Get current subscription",
    description="Get the active subscription for the current tenant.",
)
async def get_subscription(
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> SubscriptionResponse | None:
    """Get the active subscription for the current tenant."""
    subscription = await service.get_subscription(current_user.tenant_id)
    if subscription:
        return SubscriptionResponse.model_validate(subscription)
    return None


@router.get(
    "/subscriptions",
    response_model=list[SubscriptionResponse],
    summary="List subscriptions",
    description="List all subscriptions (including past) for the current tenant.",
)
async def list_subscriptions(
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
    limit: int = Query(10, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> list[SubscriptionResponse]:
    """List all subscriptions for the current tenant."""
    subscriptions = await service.list_subscriptions(
        current_user.tenant_id, limit, offset
    )
    return [SubscriptionResponse.model_validate(s) for s in subscriptions]


@router.post(
    "/subscription/{subscription_id}/cancel",
    response_model=SubscriptionResponse,
    summary="Cancel subscription",
    description="Cancel a subscription. By default, cancels at period end.",
)
async def cancel_subscription(
    subscription_id: str,
    data: SubscriptionCancelRequest,
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> SubscriptionResponse:
    """Cancel a subscription."""
    from uuid import UUID

    subscription = await service.cancel_subscription(
        tenant_id=current_user.tenant_id,
        subscription_id=UUID(subscription_id),
        data=data,
    )
    return SubscriptionResponse.model_validate(subscription)


# ============================================================
# Usage / Metered Billing
# ============================================================


@router.post(
    "/usage",
    response_model=UsageReportResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Report usage",
    description="Report metered usage for a subscription.",
)
async def report_usage(
    data: UsageReportCreate,
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> UsageReportResponse:
    """Report metered usage for a subscription."""
    usage = await service.report_usage(
        tenant_id=current_user.tenant_id,
        data=data,
    )
    return UsageReportResponse.model_validate(usage)


# ============================================================
# Invoices
# ============================================================


@router.get(
    "/invoices",
    response_model=InvoiceListResponse,
    summary="List invoices",
    description="List invoices for the current tenant.",
)
async def list_invoices(
    service: Annotated[BillingService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
    page: int = Query(1, ge=1),
    page_size: int = Query(10, ge=1, le=100),
) -> InvoiceListResponse:
    """List invoices for the current tenant."""
    invoices, total = await service.list_invoices(
        tenant_id=current_user.tenant_id,
        page=page,
        page_size=page_size,
    )
    return InvoiceListResponse(
        items=[InvoiceResponse.model_validate(i) for i in invoices],
        total=total,
        page=page,
        page_size=page_size,
    )

