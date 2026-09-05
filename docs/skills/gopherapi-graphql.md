# GopherAPI GraphQL Skill

You have access to GopherAPI — a GraphQL API for golf course management. Use it to answer questions about customers, orders, tee times, memberships, events, products, employees, reports, and more.

## Connection

- **GraphQL Endpoint:** `https://gopher.tenfore.golf/gql`
- **Auth Endpoint:** `https://gopher.tenfore.golf/auth` (REST, not GraphQL)
- **Golf Course:** Schule Oaks, `golfCourseId: 2`

## Authentication

**IMPORTANT:** Auth is a REST endpoint, NOT a GraphQL mutation. Do NOT try to authenticate via GraphQL.

**Step 1 — Get a token** (REST POST):
```bash
curl -s -X POST https://gopher.tenfore.golf/auth \
  -H "Content-Type: application/json" \
  -d '{"username": "igor@tenfore.golf", "password": "IgorPass1!"}'
```

Response:
```json
{
  "user": { "id": 17, "fullName": "Igor", "golfCourses": [...] },
  "token": "eyJhbGciOi...",
  "refreshToken": "...",
  "error": null
}
```

**Step 2 — Use the token** in all GraphQL requests:
```bash
curl -s -X POST https://gopher.tenfore.golf/gql \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOi..." \
  -d '{"query": "{ golfCourseTime(golfCourseId: 2) }"}'
```

The token is a JWT. If you get a 401 or `AUTH_NOT_AUTHORIZED` error, re-authenticate to get a fresh token.

## Request Format

```json
{
  "query": "query Name($var: Type!) { field(arg: $var) { ... } }",
  "variables": { "var": value }
}
```

Always include the `Authorization: Bearer <token>` header.

## Rules

1. **Read-only** — only use `query { }`, NEVER use `mutation { }`. No creating, updating, or deleting data.
2. **Auth is REST, not GraphQL** — use `POST /auth` to get a token, never try GraphQL mutations for auth
3. **Always include `golfCourseId: 2`** in every query that requires it
4. **Use pagination** — always pass `first` to limit results (default to 25, max 100)
5. **Select only needed fields** — don't select everything, pick what's relevant to the question
6. **Use filters** when available to narrow results server-side
7. **Use ONLY field names shown in this document** — do NOT guess field names. If a field is not listed here, do NOT use it.

## Pagination (Relay Cursor)

All paginated queries return a Connection type:

```graphql
query {
  orders(golfCourseId: 2, first: 25, after: "cursor") {
    edges {
      node { orderId dateCreated }
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

To get the next page, pass `after: pageInfo.endCursor` from the previous response.

---

## Available Queries by Domain

### Customers

**List customers** (paginated, searchable by `name`, `firstName`, `lastName`, `email`, `phoneNumber`):
```graphql
query {
  golfCourseCustomers(
    golfCourseId: 2
    first: 25
    filter: { name: "smith" }
  ) {
    edges {
      node {
        golfCourseCustomerId
        customerId
        customer {
          firstName
          lastName
          email
          phoneNumber
          dateCreated
          fullName
        }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

Filter fields: `id`, `customerId`, `name`, `firstName`, `lastName`, `phoneNumber`, `email`, `excludeDeleted`

**Customer aging report** (past-due balances):
```graphql
query {
  customerAgingReport(golfCourseId: 2, filter: {}) {
    golfCourseCustomerId
    customerId
    customerFirstName
    customerLastName
    customerFullName
    customerEmail
    customerPhone
    balanceToDate
    balance30Days
    balance60Days
    balance90Days
    totalPastDue
  }
}
```

**Customer tee times** (NOTE: this query may return a server error on some courses — use `teeTimes` with date filter as fallback):
```graphql
query {
  teeTimesByCustomer(golfCourseCustomerId: 123, first: 25) {
    edges {
      node {
        teeTimeCustomerId
        teeTimeId
        playerFirstName
        playerLastName
        only9
        isPurchased
        noShow
        teeTime {
          teeTimeId
          dateScheduled
        }
        golfCourseCustomer {
          customer { firstName lastName }
        }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

**Customer orders:**
```graphql
query {
  orders(golfCourseId: 2, first: 25, filter: { customerId: 123 }) {
    edges {
      node {
        orderId
        dateCreated
        orderStatusId
        orderItems { itemGrandTotal customItemName quantity pricePreTax }
        orderPayments { amount paymentType { description } }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

**Customer memberships:**
```graphql
query {
  customerPublicMemberships(
    golfCourseId: 2
    first: 25
    filter: { golfCourseCustomerId: 123 }
  ) {
    edges {
      node {
        customerPublicMembershipId
        startDate
        membershipStatusId
        autoRenew
        publicMembership { title price numberOfMonths }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

**Customer gift cards:**
```graphql
query {
  giftCards(golfCourseId: 2, first: 25, filter: { golfCourseCustomerId: 123 }) {
    edges {
      node {
        giftCardId
        upc
        amountAwarded
        balance
        dateExpired
        dateCreated
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

**Customer payment methods:**
```graphql
query {
  customerPaymentSources(
    golfCourseId: 2
    first: 25
    filter: { golfCourseCustomerId: 123 }
  ) {
    edges {
      node {
        paymentSourceId
        last4
        ccbrand
        expMonth
        expYear
        enabled
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Orders & Sales

**List orders** (paginated, filterable):
```graphql
query {
  orders(
    golfCourseId: 2
    first: 25
    filter: {
      dateStart: "2026-03-01T00:00:00"
      dateEnd: "2026-03-25T23:59:59"
    }
  ) {
    edges {
      node {
        orderId
        dateCreated
        dateCompleted
        orderStatusId
        notes
        customerId
        department { description }
        orderItems {
          orderItemId
          customItemName
          quantity
          pricePreTax
          itemGrandTotal
          tax
          fees
          golfCourseProduct { title sku }
        }
        orderPayments {
          amount
          paymentType { description }
          dateCreated
          last4
          creditCardBrand
        }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

Filter fields: `orderId`, `orderStatusId`, `customerId`, `golfCourseCustomerId`, `dateStart`, `dateEnd`, `departmentId`, `taxExempt`, `productCategoryId`

**Order count and total sales:**
```graphql
query {
  orderCount(golfCourseId: 2, filter: { dateStart: "2026-03-01T00:00:00", dateEnd: "2026-03-25T23:59:59" })
  totalSales(golfCourseId: 2, filter: { dateStart: "2026-03-01T00:00:00", dateEnd: "2026-03-25T23:59:59" })
}
```

### Products

**List products** (paginated, searchable by `name`):
```graphql
query {
  golfCourseProducts(
    first: 25
    filter: {
      golfCourseId: 2
      name: "glove"
    }
  ) {
    edges {
      node {
        golfCourseProductId
        title
        sku
        price
        cost
        isFeatured
        isOnHold
        description
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

Filter fields: `golfCourseId`, `golfCourseProductId`, `name`, `includeDeleted`, `isFeatured`, `productGroupId`

### Tee Times & Tee Sheet

**Tee times for a date** (use `date` filter, NOT `startDate`/`endDate`):
```graphql
query {
  teeTimes(
    golfCourseId: 2
    first: 100
    filter: {
      date: "2026-03-25T00:00:00"
    }
  ) {
    edges {
      node {
        teeTimeId
        dateScheduled
        isBlocked
        isSplit
        playerCount
        title
        subCourse { subCourseName }
        teeTimeCustomers {
          teeTimeCustomerId
          playerFirstName
          playerLastName
          only9
          isPurchased
          noShow
          checkedIn
        }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

Filter fields: `date`, `subCourseId`, `teeTimeId`, `isPast`, `isFuture`

**Tee schedules** (NOTE: this query may return a server error on some courses):
```graphql
query {
  teeSchedules(golfCourseId: 2, first: 25) {
    edges {
      node {
        teeScheduleId
        description
        gap
        hardStart
        hardStop
        isSplit
        isDefault
        shotgunGroups
        maxCustomers
        startDate
        endDate
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Events

**List events** (paginated):
```graphql
query {
  golfCourseEventPaginated(golfCourseId: 2, first: 25) {
    edges {
      node {
        eventId
        eventDescription
        startDate
        endDate
        grandTotal
        balance
        golfSubTotal
        dateCompleted
        contactName
        contactEmail
        eventStatusId
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

**Event items:**
```graphql
query {
  eventItems(golfCourseId: 2, filter: { golfCourseEventId: 456 }) {
    eventItemId
    quantity
    pricePerUnit
    pricePerUnitPreTax
    itemGrandTotal
    golfCourseProduct { title }
  }
}
```

### Employees

**List employees** (paginated — use empty filter `{}`):
```graphql
query {
  employees(
    golfCourseId: 2
    first: 25
    filter: {}
  ) {
    edges {
      node {
        employeeId
        favoriteColorHex
        user {
          name
          userName
          email
          phoneNumber
          userTypeId
        }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

Filter fields: `employeeId`, `stringInput`, `status`, `userTypeId`, `hasPin`, `hasEmail`, `hasPhone`

**IMPORTANT:** Do NOT pass `includeDeleted` or `isDeleted` to employee filter — it will cause a server error.

### Memberships

**List memberships offered:**
```graphql
query {
  listPublicMemberships(golfCourseId: 2, first: 25, filter: {}) {
    edges {
      node {
        publicMembershipId
        title
        price
        colorHex
        numberOfMonths
        autoRenew
        minimumPurchases
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

**Active members:**
```graphql
query {
  members(golfCourseId: 2, first: 25, filter: {}) {
    edges {
      node {
        memberId
        memberNumber
        customerId
        isFlagged
        customer { firstName lastName email phoneNumber fullName }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Activities

**Activity bookings for a date** (use `startTime`/`endTime` filter):
```graphql
query {
  activityBookings(
    golfCourseId: 2
    filter: {
      startTime: "2026-03-25T00:00:00"
      endTime: "2026-03-25T23:59:59"
    }
  ) {
    activityBookingId
    startTime
    endTime
    playerCount
    isPurchased
    noShow
    firstName
    lastName
    email
    phone
    activityResource { title activityType { description } }
    golfCourseCustomer { customer { firstName lastName } }
  }
}
```

Filter fields: `startTime`, `endTime`, `activityTypeId`, `activityResourceId`, `golfCourseCustomerId`, `isPurchased`, `noShow`, `deleted`, `name`

**Activity resources:**
```graphql
query {
  activityResources(golfCourseId: 2, filter: {}) {
    activityResourceId
    title
    maxCapacity
    activityType { description }
  }
}
```

### Reservations

**Restaurant reservations** (use `dateStart`/`dateEnd` filter):
```graphql
query {
  restaurantReservations(
    golfCourseId: 2
    first: 25
    filter: {
      dateStart: "2026-03-25T00:00:00"
      dateEnd: "2026-03-25T23:59:59"
    }
  ) {
    edges {
      node {
        restaurantReservationId
        reservationDate
        partySize
        notes
        customer { firstName lastName }
        restaurantReservationGroup { restaurantReservationGroupId }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Reports

**General ledger:**
```graphql
query {
  generalLedgerReport(
    golfCourseId: 2
    startDate: "2026-03-01T00:00:00"
    endDate: "2026-03-31T23:59:59"
    allCourses: false
  ) {
    items {
      generalLedgerCodeId
      description
      debit
      credit
      paymentTypeId
    }
    warnings
  }
}
```

### Gift Cards & Rain Checks

**Gift cards:**
```graphql
query {
  giftCards(golfCourseId: 2, first: 25, filter: {}) {
    edges {
      node {
        giftCardId
        upc
        amountAwarded
        balance
        dateExpired
        dateCreated
        golfCourseCustomer { customer { firstName lastName } }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

Filter fields: `golfCourseCustomerId`, `status`, `giftCardTypeId`, `asOfDate`, `paymentPending`

**Total gift card balance:**
```graphql
query {
  totalGiftCardBalance(golfCourseId: 2, filter: {})
}
```

**Rain checks:**
```graphql
query {
  rainChecks(golfCourseId: 2, first: 25, filter: {}) {
    edges {
      node {
        rainCheckId
        amount
        amountSpent
        balance
        dateExpired
        dateCreated
        teeTimeCustomer {
          playerFirstName
          playerLastName
          golfCourseCustomer { customer { firstName lastName } }
        }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Punch Cards

```graphql
query {
  customerPunchCards(golfCourseId: 2, first: 25, filter: {}) {
    edges {
      node {
        customerPunchCardId
        roundsAwarded
        roundsUsed
        transposAwarded
        transposUsed
        dateExpired
        golfCourseCustomer { customer { firstName lastName } }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Golf Course Info

**Current time at the course:**
```graphql
query {
  golfCourseTime(golfCourseId: 2)
}
```

**Sub-courses (front 9, back 9, etc.):**
```graphql
query {
  subCourses(golfCourseId: 2) {
    subCourseId
    subCourseName
    numberOfHoles
  }
}
```

**Customer types:**
```graphql
query {
  customerTypes(golfCourseId: 2) {
    customerTypeId
    description
    hexColor
  }
}
```

---

## Filter Field Reference

Each query uses different filter field names. Here are the key ones:

| Query | Date filter | Search filter | Customer filter |
|-------|------------|---------------|-----------------|
| `orders` | `dateStart` / `dateEnd` | — | `customerId` or `golfCourseCustomerId` |
| `teeTimes` | `date` (single) | — | — |
| `activityBookings` | `startTime` / `endTime` | `name` | `golfCourseCustomerId` |
| `restaurantReservations` | `dateStart` / `dateEnd` | — | — |
| `golfCourseCustomers` | `createdFrom` / `createdTo` | `name`, `firstName`, `lastName`, `email` | `customerId` |
| `employees` | — | `stringInput` | — |
| `golfCourseProducts` | — | `name` | — |
| `giftCards` | `asOfDate` | — | `golfCourseCustomerId` |
| `rainChecks` | `dateCreated`, `dateExpired` | `customerName` | `golfCourseCustomerId` |

**IMPORTANT:** Do NOT mix up filter field names between queries. Each query type has its own filter input type with different field names.

---

## Error Handling

If a query returns errors, check:
1. **Field doesn't exist** — use ONLY field names from the examples above
2. **Filter field doesn't exist** — check the filter reference table above
3. **Auth error** — token may be expired, re-authenticate
4. **Missing required arg** — most queries require `golfCourseId: 2`
5. **Server error (NullReferenceException)** — try with empty filter `{}` or fewer fields

## Tips

- When asked "how many orders this month?", use `orderCount` not fetching all orders
- When asked about money totals, use `totalSales` or `totalGiftCardBalance` aggregations
- For tee sheet views, fetch `teeTimes` for a specific date with `first: 100`
- Customer IDs come in two forms: `customerId` (global) and `golfCourseCustomerId` (course-specific)
- The `Customer` type uses `firstName`/`lastName`, but `AspNetUser` (employee user) uses `name` (single field)
- Gift card balance field is `balance`, amount is `amountAwarded` (not `originalAmount` or `currentBalance`)
- OrderPayment amount field is `amount` (not `paymentAmount`)
- Employee color field is `favoriteColorHex` (not `colorHex`)
- TeeTime date field is `dateScheduled` (not `dateTimeTeeTime`)
- CustomerType name field is `description` (not `name`)
- Always use `first: 25` unless the user asks for more or you need all records
