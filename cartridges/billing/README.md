# Billing Cartridge

Stripe integration for subscriptions, invoices, customer portal, and metered billing.

## Setup Guide

### 1. Get Your Stripe API Keys

1. Go to [Stripe Dashboard](https://dashboard.stripe.com/)
2. Navigate to **Developers > API Keys**
3. Copy your keys:
   - **Secret key**: `sk_test_...` (for backend)
   - **Publishable key**: `pk_test_...` (for frontend checkout)

> **Tip**: Use test keys during development. They start with `sk_test_` and `pk_test_`.

### 2. Configure Environment Variables

Add to your `.env` file:

```bash
# Stripe API Keys
STRIPE_SECRET_KEY=sk_test_your_secret_key
STRIPE_PUBLISHABLE_KEY=pk_test_your_publishable_key
STRIPE_WEBHOOK_SECRET=whsec_your_webhook_secret

# Optional: Default price IDs for quick checkout
STRIPE_PRICE_ID_MONTHLY=price_xxxxx
STRIPE_PRICE_ID_YEARLY=price_xxxxx
```

### 3. Run Database Migration

```bash
just migrate
```

This creates the following tables:
- `billing_customers` - Links tenants to Stripe customers
- `billing_subscriptions` - Tracks subscription status
- `billing_invoices` - Invoice history
- `billing_usage_records` - Metered usage tracking

### 4. Create Products and Prices in Stripe

1. Go to **Products** in your Stripe Dashboard
2. Click **Add Product**
3. Configure your pricing:
   - **Recurring** for subscriptions
   - **Metered** for usage-based billing
4. Copy the **Price ID** (starts with `price_`)

Example product structure:
```
Pro Plan
├── Monthly: $29/month (price_monthly_xxx)
└── Yearly: $290/year (price_yearly_xxx)
```

### 5. Set Up Webhooks

Stripe webhooks notify your app of payment events.

#### For Local Development (using Stripe CLI)

```bash
# Install Stripe CLI
brew install stripe/stripe-cli/stripe

# Login to your Stripe account
stripe login

# Forward webhooks to your local server
stripe listen --forward-to localhost:8000/api/v1/billing/webhooks
```

Copy the webhook signing secret (`whsec_...`) and add it to `.env`.

#### For Production

1. Go to **Developers > Webhooks** in Stripe Dashboard
2. Click **Add endpoint**
3. Set the URL: `https://yourdomain.com/api/v1/billing/webhooks`
4. Select events to listen for:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.paid`
   - `invoice.payment_failed`
5. Copy the **Signing secret** to your environment

## API Endpoints

All endpoints require authentication except `/webhooks`.

### Checkout

```bash
# Create a checkout session
POST /api/v1/billing/checkout
{
  "price_id": "price_xxx",
  "success_url": "https://yourapp.com/success",
  "cancel_url": "https://yourapp.com/cancel"
}
# Returns: { "session_id": "...", "url": "https://checkout.stripe.com/..." }
```

Redirect users to the returned `url` to complete payment.

### Customer Portal

Let customers manage their own billing:

```bash
# Create portal session
POST /api/v1/billing/portal
{
  "return_url": "https://yourapp.com/settings"
}
# Returns: { "url": "https://billing.stripe.com/..." }
```

### Subscriptions

```bash
# Get current subscription
GET /api/v1/billing/subscription

# List all subscriptions
GET /api/v1/billing/subscriptions?limit=10&offset=0

# Cancel subscription
POST /api/v1/billing/subscription/{subscription_id}/cancel
{
  "cancel_immediately": false  # true = cancel now, false = cancel at period end
}
```

### Metered Usage

For usage-based pricing:

```bash
# Report usage
POST /api/v1/billing/usage
{
  "subscription_id": "uuid",
  "quantity": 100,
  "action": "increment"  # or "set"
}
```

### Invoices

```bash
# List invoices
GET /api/v1/billing/invoices?page=1&page_size=10
```

## Frontend Integration Example

```typescript
// Create checkout session and redirect
async function subscribe(priceId: string) {
  const response = await fetch('/api/v1/billing/checkout', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    },
    body: JSON.stringify({
      price_id: priceId,
      success_url: `${window.location.origin}/billing/success`,
      cancel_url: `${window.location.origin}/billing/cancel`
    })
  });

  const { url } = await response.json();
  window.location.href = url;
}

// Open customer portal
async function openBillingPortal() {
  const response = await fetch('/api/v1/billing/portal', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    },
    body: JSON.stringify({
      return_url: `${window.location.origin}/settings`
    })
  });

  const { url } = await response.json();
  window.location.href = url;
}
```

## Testing

### Test Cards

Use these test card numbers in test mode:

| Scenario | Card Number |
|----------|-------------|
| Successful payment | 4242 4242 4242 4242 |
| Declined | 4000 0000 0000 0002 |
| Requires authentication | 4000 0025 0000 3155 |
| Insufficient funds | 4000 0000 0000 9995 |

Use any future expiry date and any 3-digit CVC.

### Test Webhooks

```bash
# Trigger test events
stripe trigger checkout.session.completed
stripe trigger invoice.paid
stripe trigger customer.subscription.deleted
```

## Going to Production

1. **Switch to live keys**: Replace test keys with live keys in production
2. **Configure production webhook**: Add your production URL in Stripe Dashboard
3. **Enable billing portal**: Configure portal in Stripe Dashboard > Settings > Billing > Customer portal
4. **Set up tax collection**: Configure Stripe Tax if needed
5. **Review webhook events**: Ensure all necessary events are selected

## Troubleshooting

### Webhook signature verification failed

- Ensure `STRIPE_WEBHOOK_SECRET` matches the webhook endpoint's signing secret
- Check that the raw request body is passed to verification (not parsed JSON)

### Customer not found

- Customers are created automatically during checkout
- Ensure the user is authenticated when calling billing endpoints

### Subscription status not updating

- Check webhook logs in Stripe Dashboard
- Verify your webhook endpoint is receiving events
- Check application logs for processing errors
