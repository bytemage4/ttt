# Notification Templating System Design

## Overview

This document describes the design of a database-backed templating system for notifications (email, webhook, SMS) using Handlebars.java. The system supports ~100 notification categories with category-specific presenters, versioned templates with drafts, user-scoped templates, and reusable partials.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Notification Request                               │
│                    (category, payload, recipient, userId)                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          PresenterRegistry                                   │
│                    Routes category → NotificationPresenter                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
          ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
          │ InvoicePresenter│ │ PaymentPresenter│ │ AccountPresenter│
          │  (5 categories) │ │  (4 categories) │ │  (6 categories) │
          └─────────────────┘ └─────────────────┘ └─────────────────┘
                    │                 │                 │
                    └─────────────────┼─────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │         CommonPresenters            │
                    │  (shared formatting & context)      │
                    └─────────────────────────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │    Map<String, Object> context      │
                    └─────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       TemplateRenderingService                               │
│                                                                              │
│  ┌──────────────────────┐    ┌──────────────────────┐                       │
│  │ DatabaseTemplateLoader│───▶│      Handlebars      │                       │
│  │   (resolves partials) │    │   (compile + apply)  │                       │
│  └──────────────────────┘    └──────────────────────┘                       │
│              │                         │                                     │
│              ▼                         ▼                                     │
│  ┌──────────────────────┐    ┌──────────────────────┐                       │
│  │   TemplateRepository │    │    HelperRegistry    │                       │
│  │      (MySQL/PG)      │    │ (formatDate, etc.)   │                       │
│  └──────────────────────┘    └──────────────────────┘                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │         RenderedTemplate            │
                    │   (channel, subject, body)          │
                    └─────────────────────────────────────┘
```

---

## Database Schema

### Design Decisions

- **Version 0 convention**: Drafts are always version 0; published versions are 1, 2, 3... This provides a natural unique constraint without partial indexes (MySQL-compatible).
- **Partials are templates**: Distinguished by `type` column, referenced by `slug`. No separate table needed.
- **Soft delete**: Templates can be archived rather than deleted (preserves referential integrity for sent notifications).
- **Category mapping**: Templates are linked to notification categories via a mapping table, allowing one template to serve multiple related categories.

### Flyway Migrations

#### V1__create_templates_schema.sql

```sql
CREATE TABLE templates (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT NOT NULL,
    slug VARCHAR(100) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    type ENUM('TEMPLATE', 'PARTIAL', 'LAYOUT') NOT NULL DEFAULT 'TEMPLATE',
    channel ENUM('EMAIL', 'WEBHOOK', 'SMS') NULL,
    subject_template VARCHAR(500) NULL,
    
    status ENUM('ACTIVE', 'ARCHIVED') NOT NULL DEFAULT 'ACTIVE',
    current_version INT NULL,
    
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    CONSTRAINT uq_template_user_slug UNIQUE (user_id, slug),
    INDEX idx_template_user_type (user_id, type, status),
    INDEX idx_template_user_channel (user_id, channel, status)
);

CREATE TABLE template_versions (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    template_id BIGINT NOT NULL,
    version INT NOT NULL,
    content TEXT NOT NULL,
    
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    published_at TIMESTAMP NULL,
    published_by BIGINT NULL,
    
    CONSTRAINT fk_version_template FOREIGN KEY (template_id) 
        REFERENCES templates(id) ON DELETE CASCADE,
    CONSTRAINT uq_template_version UNIQUE (template_id, version)
);

CREATE TABLE template_partial_usage (
    template_id BIGINT NOT NULL,
    partial_id BIGINT NOT NULL,
    
    PRIMARY KEY (template_id, partial_id),
    CONSTRAINT fk_usage_template FOREIGN KEY (template_id) 
        REFERENCES templates(id) ON DELETE CASCADE,
    CONSTRAINT fk_usage_partial FOREIGN KEY (partial_id) 
        REFERENCES templates(id) ON DELETE CASCADE
);
```

#### V2__create_notification_categories_schema.sql

```sql
CREATE TABLE notification_categories (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(100) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    channel ENUM('EMAIL', 'WEBHOOK', 'SMS') NOT NULL,
    category_group VARCHAR(100) NOT NULL,
    
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_category_group (category_group),
    INDEX idx_category_channel (channel)
);

CREATE TABLE template_category_mapping (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT NOT NULL,
    category_code VARCHAR(100) NOT NULL,
    template_id BIGINT NOT NULL,
    
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT fk_mapping_template FOREIGN KEY (template_id)
        REFERENCES templates(id) ON DELETE CASCADE,
    CONSTRAINT uq_user_category UNIQUE (user_id, category_code),
    INDEX idx_mapping_user (user_id)
);

-- Seed notification categories (~100 categories organized by group)
INSERT INTO notification_categories (code, name, channel, category_group) VALUES
-- Invoice group
('invoice-created', 'Invoice Created', 'EMAIL', 'invoice'),
('invoice-sent', 'Invoice Sent', 'EMAIL', 'invoice'),
('invoice-due-soon', 'Invoice Due Soon', 'EMAIL', 'invoice'),
('invoice-due-today', 'Invoice Due Today', 'EMAIL', 'invoice'),
('invoice-overdue', 'Invoice Overdue', 'EMAIL', 'invoice'),
('invoice-final-reminder', 'Invoice Final Reminder', 'EMAIL', 'invoice'),
('invoice-paid', 'Invoice Paid', 'EMAIL', 'invoice'),
('invoice-partially-paid', 'Invoice Partially Paid', 'EMAIL', 'invoice'),
('invoice-disputed', 'Invoice Disputed', 'EMAIL', 'invoice'),
('invoice-cancelled', 'Invoice Cancelled', 'EMAIL', 'invoice'),
-- Payment group
('payment-received', 'Payment Received', 'EMAIL', 'payment'),
('payment-failed', 'Payment Failed', 'EMAIL', 'payment'),
('payment-refunded', 'Payment Refunded', 'EMAIL', 'payment'),
('payment-pending', 'Payment Pending', 'EMAIL', 'payment'),
('payment-method-expiring', 'Payment Method Expiring', 'EMAIL', 'payment'),
('payment-method-updated', 'Payment Method Updated', 'EMAIL', 'payment'),
-- Account group
('account-created', 'Account Created', 'EMAIL', 'account'),
('account-verified', 'Account Verified', 'EMAIL', 'account'),
('account-locked', 'Account Locked', 'EMAIL', 'account'),
('password-reset-requested', 'Password Reset Requested', 'EMAIL', 'account'),
('password-changed', 'Password Changed', 'EMAIL', 'account'),
('email-changed', 'Email Changed', 'EMAIL', 'account'),
('two-factor-enabled', 'Two-Factor Enabled', 'EMAIL', 'account'),
-- Subscription group
('subscription-created', 'Subscription Created', 'EMAIL', 'subscription'),
('subscription-renewed', 'Subscription Renewed', 'EMAIL', 'subscription'),
('subscription-cancelled', 'Subscription Cancelled', 'EMAIL', 'subscription'),
('subscription-expiring', 'Subscription Expiring', 'EMAIL', 'subscription'),
('subscription-expired', 'Subscription Expired', 'EMAIL', 'subscription'),
('subscription-upgraded', 'Subscription Upgraded', 'EMAIL', 'subscription'),
('subscription-downgraded', 'Subscription Downgraded', 'EMAIL', 'subscription'),
-- Webhook events
('webhook-invoice-created', 'Invoice Created Webhook', 'WEBHOOK', 'webhook'),
('webhook-invoice-paid', 'Invoice Paid Webhook', 'WEBHOOK', 'webhook'),
('webhook-payment-received', 'Payment Received Webhook', 'WEBHOOK', 'webhook'),
('webhook-subscription-changed', 'Subscription Changed Webhook', 'WEBHOOK', 'webhook');
```

#### V3__create_template_variables_schema.sql

```sql
CREATE TABLE template_variables (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    template_id BIGINT NOT NULL,
    name VARCHAR(100) NOT NULL,
    json_path VARCHAR(255) NOT NULL,
    data_type ENUM('STRING', 'NUMBER', 'DATE', 'BOOLEAN', 'ARRAY', 'OBJECT') NOT NULL,
    required BOOLEAN NOT NULL DEFAULT FALSE,
    description VARCHAR(500),
    example_value VARCHAR(500),
    
    CONSTRAINT fk_variable_template FOREIGN KEY (template_id)
        REFERENCES templates(id) ON DELETE CASCADE,
    CONSTRAINT uq_template_variable UNIQUE (template_id, name)
);
```

---

## Domain Entities

### Template.java

```java
@Entity
@Table(name = "templates")
@Getter
@Setter
@NoArgsConstructor
public class Template {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "user_id", nullable = false)
    private Long userId;

    @Column(nullable = false, length = 100)
    private String slug;

    @Column(nullable = false)
    private String name;

    private String description;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private TemplateType type;

    @Enumerated(EnumType.STRING)
    private Channel channel;

    @Column(name = "subject_template", length = 500)
    private String subjectTemplate;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private TemplateStatus status = TemplateStatus.ACTIVE;

    @Column(name = "current_version")
    private Integer currentVersion;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @OneToMany(mappedBy = "template", cascade = CascadeType.ALL, orphanRemoval = true)
    @OrderBy("version DESC")
    private List<TemplateVersion> versions = new ArrayList<>();

    @PrePersist
    void onCreate() {
        createdAt = updatedAt = Instant.now();
    }

    @PreUpdate
    void onUpdate() {
        updatedAt = Instant.now();
    }

    public Optional<TemplateVersion> getDraft() {
        return versions.stream()
            .filter(v -> v.getVersion() == 0)
            .findFirst();
    }

    public Optional<TemplateVersion> getPublishedVersion(int version) {
        return versions.stream()
            .filter(v -> v.getVersion() == version)
            .findFirst();
    }

    public Optional<TemplateVersion> getLatestPublished() {
        return currentVersion != null 
            ? getPublishedVersion(currentVersion) 
            : Optional.empty();
    }

    public boolean hasPublishedVersion() {
        return currentVersion != null;
    }
}
```

### TemplateVersion.java

```java
@Entity
@Table(name = "template_versions")
@Getter
@Setter
@NoArgsConstructor
public class TemplateVersion {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "template_id", nullable = false)
    private Template template;

    @Column(nullable = false)
    private Integer version;

    @Column(nullable = false, columnDefinition = "TEXT")
    private String content;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "published_at")
    private Instant publishedAt;

    @Column(name = "published_by")
    private Long publishedBy;

    @PrePersist
    void onCreate() {
        createdAt = Instant.now();
    }

    public boolean isDraft() {
        return version == 0;
    }

    public boolean isPublished() {
        return version > 0;
    }
}
```

### NotificationCategory.java

```java
@Entity
@Table(name = "notification_categories")
@Getter
@Setter
@NoArgsConstructor
public class NotificationCategory {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true, length = 100)
    private String code;

    @Column(nullable = false)
    private String name;

    private String description;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private Channel channel;

    @Column(name = "category_group", nullable = false, length = 100)
    private String categoryGroup;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    void onCreate() {
        createdAt = Instant.now();
    }
}
```

### Enums

```java
public enum TemplateType {
    TEMPLATE,
    PARTIAL,
    LAYOUT
}

public enum TemplateStatus {
    ACTIVE,
    ARCHIVED
}

public enum Channel {
    EMAIL,
    WEBHOOK,
    SMS
}
```

---

## Repositories

### TemplateRepository.java

```java
public interface TemplateRepository extends JpaRepository<Template, Long> {

    Optional<Template> findByUserIdAndSlug(Long userId, String slug);

    List<Template> findByUserIdAndTypeAndStatus(Long userId, TemplateType type, TemplateStatus status);

    @Query("""
        SELECT t FROM Template t
        JOIN FETCH t.versions v
        WHERE t.userId = :userId 
          AND t.slug = :slug 
          AND t.status = 'ACTIVE'
          AND v.version = COALESCE(t.currentVersion, 0)
        """)
    Optional<Template> findWithCurrentContent(@Param("userId") Long userId, 
                                               @Param("slug") String slug);

    @Query("""
        SELECT t FROM Template t
        JOIN FETCH t.versions v
        WHERE t.userId = :userId 
          AND t.type = 'PARTIAL' 
          AND t.status = 'ACTIVE'
          AND t.currentVersion IS NOT NULL
          AND v.version = t.currentVersion
        """)
    List<Template> findPublishedPartials(@Param("userId") Long userId);

    @Query("""
        SELECT t FROM Template t
        WHERE t.userId = :userId
          AND t.type = :type
          AND t.status = 'ACTIVE'
        ORDER BY t.name
        """)
    List<Template> findActiveByUserAndType(@Param("userId") Long userId, 
                                            @Param("type") TemplateType type);
}
```

### TemplateCategoryMappingRepository.java

```java
public interface TemplateCategoryMappingRepository 
        extends JpaRepository<TemplateCategoryMapping, Long> {

    Optional<TemplateCategoryMapping> findByUserIdAndCategoryCode(Long userId, String categoryCode);

    List<TemplateCategoryMapping> findByUserId(Long userId);

    @Query("""
        SELECT t FROM Template t
        JOIN TemplateCategoryMapping m ON m.templateId = t.id
        WHERE m.userId = :userId AND m.categoryCode = :categoryCode
        """)
    Optional<Template> findTemplateForCategory(@Param("userId") Long userId,
                                                @Param("categoryCode") String categoryCode);
}
```

---

## Handlebars Configuration

### HandlebarsConfig.java

```java
@Configuration
public class HandlebarsConfig {

    @Bean
    public Handlebars handlebars(DatabaseTemplateLoader templateLoader,
                                  HelperRegistry helperRegistry) {
        Handlebars handlebars = new Handlebars(templateLoader);
        
        helperRegistry.registerAll(handlebars);
        
        handlebars.setPrettyPrint(false);
        handlebars.setInfiniteLoops(false);
        handlebars.setStringParams(true);
        
        // Register built-in helpers
        handlebars.registerHelpers(ConditionalHelpers.class);
        handlebars.registerHelpers(StringHelpers.class);
        
        return handlebars;
    }
}
```

### DatabaseTemplateLoader.java

```java
@Component
public class DatabaseTemplateLoader implements TemplateLoader {

    private final TemplateRepository templateRepository;
    private final Cache<String, CachedTemplate> cache;

    private static final ThreadLocal<Long> currentUserId = new ThreadLocal<>();

    public DatabaseTemplateLoader(TemplateRepository templateRepository) {
        this.templateRepository = templateRepository;
        this.cache = Caffeine.newBuilder()
            .maximumSize(1000)
            .expireAfterWrite(Duration.ofMinutes(5))
            .build();
    }

    public static void setCurrentUser(Long userId) {
        currentUserId.set(userId);
    }

    public static void clearCurrentUser() {
        currentUserId.remove();
    }

    public static Long getCurrentUser() {
        return currentUserId.get();
    }

    @Override
    public TemplateSource sourceAt(String location) throws IOException {
        Long userId = currentUserId.get();
        if (userId == null) {
            throw new IllegalStateException("No user context set for template loading");
        }

        String cacheKey = userId + ":" + location;
        CachedTemplate cached = cache.get(cacheKey, key -> loadTemplate(userId, location));

        if (cached == null) {
            throw new FileNotFoundException("Template not found: " + location);
        }

        return new StringTemplateSource(location, cached.content(), cached.lastModified());
    }

    private CachedTemplate loadTemplate(Long userId, String slug) {
        return templateRepository.findWithCurrentContent(userId, slug)
            .flatMap(Template::getLatestPublished)
            .map(v -> new CachedTemplate(v.getContent(), v.getPublishedAt().toEpochMilli()))
            .orElse(null);
    }

    public void evict(Long userId, String slug) {
        cache.invalidate(userId + ":" + slug);
    }

    public void evictAll(Long userId) {
        cache.asMap().keySet().removeIf(key -> key.startsWith(userId + ":"));
    }

    private record CachedTemplate(String content, long lastModified) {}
}
```

---

## Category-Specific Presenter System

### Core Interfaces

#### NotificationRequest.java

```java
@Getter
@RequiredArgsConstructor
public class NotificationRequest {
    
    private final String category;
    private final Long userId;
    private final Object payload;
    private final Recipient recipient;
    private final Map<String, Object> metadata;

    public <T> T getPayload(Class<T> type) {
        return type.cast(payload);
    }

    public <T> Optional<T> getMetadata(String key, Class<T> type) {
        Object value = metadata.get(key);
        return value != null ? Optional.of(type.cast(value)) : Optional.empty();
    }
}
```

#### NotificationPresenter.java

```java
public interface NotificationPresenter {
    
    /**
     * Returns the set of category codes this presenter handles.
     * Multiple related categories can share a single presenter.
     */
    Set<String> supportedCategories();

    /**
     * Transforms the notification request into a template context.
     * This is where business logic lives: what to show, what to hide,
     * calculated fields, conditional content flags.
     */
    Map<String, Object> present(NotificationRequest request);
    
    /**
     * Returns the default template slug for a category.
     * Users can override this via template_category_mapping.
     */
    default String defaultTemplateSlug(String category) {
        return category; // By default, template slug matches category code
    }
}
```

### Common Presenters (Shared Components)

#### CommonPresenters.java

```java
@Component
@RequiredArgsConstructor
public class CommonPresenters {

    private final Clock clock;

    public Map<String, Object> presentRecipient(Recipient recipient) {
        return Map.of(
            "name", recipient.getFullName(),
            "firstName", recipient.getFirstName(),
            "lastName", recipient.getLastName(),
            "email", recipient.getEmail(),
            "locale", recipient.getPreferredLocale().toLanguageTag(),
            "timezone", recipient.getTimeZone().getId()
        );
    }

    public Map<String, Object> presentMoney(BigDecimal amount, Currency currency, Locale locale) {
        NumberFormat formatter = NumberFormat.getCurrencyInstance(locale);
        formatter.setCurrency(currency);
        
        return Map.of(
            "raw", amount,
            "formatted", formatter.format(amount),
            "currencyCode", currency.getCurrencyCode(),
            "currencySymbol", currency.getSymbol(locale)
        );
    }

    public Map<String, Object> presentDate(LocalDate date, Locale locale, ZoneId zone) {
        DateTimeFormatter shortFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT)
            .withLocale(locale);
        DateTimeFormatter longFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG)
            .withLocale(locale);
        
        return Map.of(
            "raw", date.toString(),
            "short", date.format(shortFormatter),
            "long", date.format(longFormatter),
            "iso", date.format(DateTimeFormatter.ISO_LOCAL_DATE)
        );
    }

    public Map<String, Object> presentDateTime(Instant instant, Locale locale, ZoneId zone) {
        ZonedDateTime zdt = instant.atZone(zone);
        DateTimeFormatter formatter = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM)
            .withLocale(locale);
        
        return Map.of(
            "raw", instant.toString(),
            "formatted", zdt.format(formatter),
            "date", presentDate(zdt.toLocalDate(), locale, zone),
            "time", zdt.format(DateTimeFormatter.ofPattern("HH:mm"))
        );
    }

    public Map<String, Object> presentAddress(Address address) {
        return Map.of(
            "line1", address.getLine1(),
            "line2", Optional.ofNullable(address.getLine2()).orElse(""),
            "city", address.getCity(),
            "state", Optional.ofNullable(address.getState()).orElse(""),
            "postalCode", address.getPostalCode(),
            "country", address.getCountry(),
            "formatted", formatAddress(address)
        );
    }

    public Map<String, Object> presentCompany(Company company, Locale locale) {
        return Map.of(
            "name", company.getName(),
            "legalName", Optional.ofNullable(company.getLegalName()).orElse(company.getName()),
            "email", company.getEmail(),
            "phone", Optional.ofNullable(company.getPhone()).orElse(""),
            "website", Optional.ofNullable(company.getWebsite()).orElse(""),
            "address", presentAddress(company.getAddress()),
            "logo", Optional.ofNullable(company.getLogoUrl()).orElse("")
        );
    }

    public LocalDate today(ZoneId zone) {
        return LocalDate.now(clock.withZone(zone));
    }

    private String formatAddress(Address address) {
        StringBuilder sb = new StringBuilder();
        sb.append(address.getLine1());
        if (address.getLine2() != null && !address.getLine2().isBlank()) {
            sb.append(", ").append(address.getLine2());
        }
        sb.append(", ").append(address.getCity());
        if (address.getState() != null && !address.getState().isBlank()) {
            sb.append(", ").append(address.getState());
        }
        sb.append(" ").append(address.getPostalCode());
        sb.append(", ").append(address.getCountry());
        return sb.toString();
    }
}
```

#### UrlBuilder.java

```java
@Component
@RequiredArgsConstructor
public class UrlBuilder {

    @Value("${app.base-url}")
    private String baseUrl;

    public String invoiceViewUrl(Invoice invoice) {
        return baseUrl + "/invoices/" + invoice.getPublicId();
    }

    public String invoicePaymentUrl(Invoice invoice) {
        return baseUrl + "/pay/" + invoice.getPublicId();
    }

    public String invoiceDisputeUrl(Invoice invoice) {
        return baseUrl + "/invoices/" + invoice.getPublicId() + "/dispute";
    }

    public String invoicePdfUrl(Invoice invoice) {
        return baseUrl + "/invoices/" + invoice.getPublicId() + "/pdf";
    }

    public String subscriptionManageUrl(Subscription subscription) {
        return baseUrl + "/subscriptions/" + subscription.getId() + "/manage";
    }

    public String accountSettingsUrl() {
        return baseUrl + "/settings/account";
    }

    public String passwordResetUrl(String token) {
        return baseUrl + "/auth/reset-password?token=" + token;
    }

    public String verifyEmailUrl(String token) {
        return baseUrl + "/auth/verify-email?token=" + token;
    }

    public String unsubscribeUrl(String token) {
        return baseUrl + "/unsubscribe?token=" + token;
    }
}
```

### Category-Specific Presenters

#### InvoicePresenter.java

```java
@Component
@RequiredArgsConstructor
public class InvoicePresenter implements NotificationPresenter {

    private final CommonPresenters common;
    private final UrlBuilder urlBuilder;

    @Override
    public Set<String> supportedCategories() {
        return Set.of(
            "invoice-created",
            "invoice-sent",
            "invoice-due-soon",
            "invoice-due-today",
            "invoice-overdue",
            "invoice-final-reminder",
            "invoice-paid",
            "invoice-partially-paid",
            "invoice-disputed",
            "invoice-cancelled"
        );
    }

    @Override
    public Map<String, Object> present(NotificationRequest request) {
        Invoice invoice = request.getPayload(Invoice.class);
        Recipient recipient = request.getRecipient();
        Locale locale = recipient.getPreferredLocale();
        ZoneId zone = recipient.getTimeZone();
        LocalDate today = common.today(zone);

        long daysUntilDue = ChronoUnit.DAYS.between(today, invoice.getDueDate());
        boolean isOverdue = daysUntilDue < 0;

        return Map.of(
            "category", request.getCategory(),
            "recipient", common.presentRecipient(recipient),
            "invoice", buildInvoiceContext(invoice, locale, zone, daysUntilDue, isOverdue),
            "company", common.presentCompany(invoice.getIssuer(), locale),
            "actions", buildActions(invoice, isOverdue),
            "flags", buildFlags(request.getCategory(), invoice, isOverdue, daysUntilDue)
        );
    }

    private Map<String, Object> buildInvoiceContext(Invoice invoice, Locale locale, ZoneId zone,
                                                     long daysUntilDue, boolean isOverdue) {
        Map<String, Object> ctx = new HashMap<>();
        
        ctx.put("number", invoice.getNumber());
        ctx.put("total", common.presentMoney(invoice.getTotal(), invoice.getCurrency(), locale));
        ctx.put("amountDue", common.presentMoney(invoice.getAmountDue(), invoice.getCurrency(), locale));
        ctx.put("amountPaid", common.presentMoney(invoice.getAmountPaid(), invoice.getCurrency(), locale));
        ctx.put("issueDate", common.presentDate(invoice.getIssueDate(), locale, zone));
        ctx.put("dueDate", common.presentDate(invoice.getDueDate(), locale, zone));
        
        ctx.put("isOverdue", isOverdue);
        ctx.put("daysUntilDue", Math.max(0, daysUntilDue));
        ctx.put("daysOverdue", isOverdue ? Math.abs(daysUntilDue) : 0);
        ctx.put("isPaid", invoice.getStatus() == InvoiceStatus.PAID);
        ctx.put("isPartiallyPaid", invoice.getAmountPaid().compareTo(BigDecimal.ZERO) > 0 
                                   && invoice.getAmountDue().compareTo(BigDecimal.ZERO) > 0);

        // Line items
        ctx.put("lineItems", invoice.getLineItems().stream()
            .map(item -> presentLineItem(item, invoice.getCurrency(), locale))
            .toList());
        ctx.put("lineItemCount", invoice.getLineItems().size());

        // Late fee calculation (if applicable)
        if (isOverdue && invoice.getLateFeePolicy() != null) {
            BigDecimal lateFee = invoice.getLateFeePolicy().calculate(invoice);
            ctx.put("lateFee", common.presentMoney(lateFee, invoice.getCurrency(), locale));
            ctx.put("hasLateFee", lateFee.compareTo(BigDecimal.ZERO) > 0);
        } else {
            ctx.put("hasLateFee", false);
        }

        return ctx;
    }

    private Map<String, Object> presentLineItem(InvoiceLineItem item, Currency currency, Locale locale) {
        return Map.of(
            "description", item.getDescription(),
            "quantity", item.getQuantity(),
            "unitPrice", common.presentMoney(item.getUnitPrice(), currency, locale),
            "amount", common.presentMoney(item.getAmount(), currency, locale)
        );
    }

    private Map<String, Object> buildActions(Invoice invoice, boolean isOverdue) {
        return Map.of(
            "viewUrl", urlBuilder.invoiceViewUrl(invoice),
            "payUrl", urlBuilder.invoicePaymentUrl(invoice),
            "pdfUrl", urlBuilder.invoicePdfUrl(invoice),
            "disputeUrl", urlBuilder.invoiceDisputeUrl(invoice),
            "canPay", invoice.getStatus() != InvoiceStatus.PAID,
            "canDispute", !isOverdue && invoice.isDisputable()
        );
    }

    private Map<String, Object> buildFlags(String category, Invoice invoice, 
                                            boolean isOverdue, long daysUntilDue) {
        String urgency = switch (category) {
            case "invoice-final-reminder" -> "critical";
            case "invoice-overdue" -> "high";
            case "invoice-due-today" -> "high";
            case "invoice-due-soon" -> daysUntilDue <= 3 ? "medium" : "low";
            default -> "normal";
        };

        return Map.of(
            "urgency", urgency,
            "showLateFeeWarning", isOverdue && invoice.getLateFeePolicy() != null,
            "showPaymentButton", invoice.getStatus() != InvoiceStatus.PAID,
            "showDisputeLink", !isOverdue && invoice.isDisputable(),
            "showLineItems", category.equals("invoice-created") || category.equals("invoice-sent"),
            "isReminder", category.contains("reminder") || category.contains("due")
        );
    }

    @Override
    public String defaultTemplateSlug(String category) {
        // Group related categories to share templates
        return switch (category) {
            case "invoice-due-soon", "invoice-due-today" -> "invoice-due-reminder";
            case "invoice-overdue", "invoice-final-reminder" -> "invoice-overdue";
            default -> category;
        };
    }
}
```

#### PaymentPresenter.java

```java
@Component
@RequiredArgsConstructor
public class PaymentPresenter implements NotificationPresenter {

    private final CommonPresenters common;
    private final UrlBuilder urlBuilder;

    @Override
    public Set<String> supportedCategories() {
        return Set.of(
            "payment-received",
            "payment-failed",
            "payment-refunded",
            "payment-pending",
            "payment-method-expiring",
            "payment-method-updated"
        );
    }

    @Override
    public Map<String, Object> present(NotificationRequest request) {
        Recipient recipient = request.getRecipient();
        Locale locale = recipient.getPreferredLocale();
        ZoneId zone = recipient.getTimeZone();

        return switch (request.getCategory()) {
            case "payment-received", "payment-failed", "payment-refunded", "payment-pending" -> 
                presentPaymentEvent(request, locale, zone);
            case "payment-method-expiring", "payment-method-updated" -> 
                presentPaymentMethodEvent(request, locale, zone);
            default -> throw new IllegalArgumentException("Unsupported category: " + request.getCategory());
        };
    }

    private Map<String, Object> presentPaymentEvent(NotificationRequest request, 
                                                     Locale locale, ZoneId zone) {
        Payment payment = request.getPayload(Payment.class);
        Recipient recipient = request.getRecipient();

        Map<String, Object> paymentCtx = new HashMap<>();
        paymentCtx.put("id", payment.getPublicId());
        paymentCtx.put("amount", common.presentMoney(payment.getAmount(), payment.getCurrency(), locale));
        paymentCtx.put("date", common.presentDateTime(payment.getCreatedAt(), locale, zone));
        paymentCtx.put("method", presentPaymentMethod(payment.getPaymentMethod()));
        paymentCtx.put("status", payment.getStatus().name().toLowerCase());
        
        if (payment.getInvoice() != null) {
            paymentCtx.put("invoiceNumber", payment.getInvoice().getNumber());
            paymentCtx.put("invoiceUrl", urlBuilder.invoiceViewUrl(payment.getInvoice()));
        }

        // Failure details
        if (payment.getStatus() == PaymentStatus.FAILED) {
            paymentCtx.put("failureReason", payment.getFailureReason());
            paymentCtx.put("failureCode", payment.getFailureCode());
            paymentCtx.put("canRetry", payment.isRetryable());
        }

        // Refund details
        if (payment.getRefund() != null) {
            paymentCtx.put("refundAmount", common.presentMoney(
                payment.getRefund().getAmount(), payment.getCurrency(), locale));
            paymentCtx.put("refundReason", payment.getRefund().getReason());
        }

        return Map.of(
            "category", request.getCategory(),
            "recipient", common.presentRecipient(recipient),
            "payment", paymentCtx,
            "actions", Map.of(
                "accountUrl", urlBuilder.accountSettingsUrl(),
                "retryUrl", payment.isRetryable() 
                    ? urlBuilder.invoicePaymentUrl(payment.getInvoice()) : null
            ),
            "flags", Map.of(
                "isSuccess", payment.getStatus() == PaymentStatus.SUCCEEDED,
                "isFailed", payment.getStatus() == PaymentStatus.FAILED,
                "isRefund", payment.getRefund() != null,
                "hasInvoice", payment.getInvoice() != null
            )
        );
    }

    private Map<String, Object> presentPaymentMethodEvent(NotificationRequest request,
                                                           Locale locale, ZoneId zone) {
        PaymentMethod method = request.getPayload(PaymentMethod.class);
        Recipient recipient = request.getRecipient();

        return Map.of(
            "category", request.getCategory(),
            "recipient", common.presentRecipient(recipient),
            "paymentMethod", presentPaymentMethod(method),
            "actions", Map.of(
                "updateUrl", urlBuilder.accountSettingsUrl() + "/payment-methods"
            ),
            "flags", Map.of(
                "isExpiring", request.getCategory().equals("payment-method-expiring"),
                "daysUntilExpiry", method.getExpiryDate() != null 
                    ? ChronoUnit.DAYS.between(common.today(zone), method.getExpiryDate()) : 0
            )
        );
    }

    private Map<String, Object> presentPaymentMethod(PaymentMethod method) {
        return Map.of(
            "type", method.getType().name().toLowerCase(),
            "brand", Optional.ofNullable(method.getBrand()).orElse(""),
            "last4", Optional.ofNullable(method.getLast4()).orElse("****"),
            "expiryMonth", method.getExpiryMonth(),
            "expiryYear", method.getExpiryYear(),
            "displayName", buildDisplayName(method)
        );
    }

    private String buildDisplayName(PaymentMethod method) {
        if (method.getBrand() != null && method.getLast4() != null) {
            return method.getBrand() + " •••• " + method.getLast4();
        }
        return method.getType().name();
    }
}
```

#### AccountPresenter.java

```java
@Component
@RequiredArgsConstructor
public class AccountPresenter implements NotificationPresenter {

    private final CommonPresenters common;
    private final UrlBuilder urlBuilder;

    @Override
    public Set<String> supportedCategories() {
        return Set.of(
            "account-created",
            "account-verified",
            "account-locked",
            "password-reset-requested",
            "password-changed",
            "email-changed",
            "two-factor-enabled"
        );
    }

    @Override
    public Map<String, Object> present(NotificationRequest request) {
        Recipient recipient = request.getRecipient();
        Locale locale = recipient.getPreferredLocale();
        ZoneId zone = recipient.getTimeZone();

        Map<String, Object> context = new HashMap<>();
        context.put("category", request.getCategory());
        context.put("recipient", common.presentRecipient(recipient));
        context.put("timestamp", common.presentDateTime(Instant.now(), locale, zone));

        // Category-specific context
        switch (request.getCategory()) {
            case "password-reset-requested" -> {
                String token = request.getMetadata("resetToken", String.class).orElseThrow();
                int expiryMinutes = request.getMetadata("expiryMinutes", Integer.class).orElse(60);
                context.put("actions", Map.of(
                    "resetUrl", urlBuilder.passwordResetUrl(token),
                    "expiryMinutes", expiryMinutes
                ));
                context.put("security", Map.of(
                    "ipAddress", request.getMetadata("ipAddress", String.class).orElse("Unknown"),
                    "userAgent", request.getMetadata("userAgent", String.class).orElse("Unknown")
                ));
            }
            case "account-created" -> {
                String token = request.getMetadata("verificationToken", String.class).orElse(null);
                context.put("actions", Map.of(
                    "verifyUrl", token != null ? urlBuilder.verifyEmailUrl(token) : null,
                    "loginUrl", urlBuilder.accountSettingsUrl()
                ));
                context.put("flags", Map.of(
                    "requiresVerification", token != null
                ));
            }
            case "email-changed" -> {
                String oldEmail = request.getMetadata("oldEmail", String.class).orElse("");
                String newEmail = request.getMetadata("newEmail", String.class).orElse(recipient.getEmail());
                context.put("emailChange", Map.of(
                    "oldEmail", oldEmail,
                    "newEmail", newEmail
                ));
            }
            case "account-locked" -> {
                String reason = request.getMetadata("lockReason", String.class).orElse("Security concern");
                context.put("lockDetails", Map.of(
                    "reason", reason,
                    "supportEmail", "support@example.com"
                ));
            }
            default -> {
                context.put("actions", Map.of(
                    "settingsUrl", urlBuilder.accountSettingsUrl()
                ));
            }
        }

        context.put("flags", buildSecurityFlags(request));
        return context;
    }

    private Map<String, Object> buildSecurityFlags(NotificationRequest request) {
        return Map.of(
            "isSecurityAlert", Set.of("password-changed", "email-changed", "account-locked", "two-factor-enabled")
                .contains(request.getCategory()),
            "requiresAction", Set.of("password-reset-requested", "account-created")
                .contains(request.getCategory())
        );
    }
}
```

#### SubscriptionPresenter.java

```java
@Component
@RequiredArgsConstructor
public class SubscriptionPresenter implements NotificationPresenter {

    private final CommonPresenters common;
    private final UrlBuilder urlBuilder;

    @Override
    public Set<String> supportedCategories() {
        return Set.of(
            "subscription-created",
            "subscription-renewed",
            "subscription-cancelled",
            "subscription-expiring",
            "subscription-expired",
            "subscription-upgraded",
            "subscription-downgraded"
        );
    }

    @Override
    public Map<String, Object> present(NotificationRequest request) {
        Subscription subscription = request.getPayload(Subscription.class);
        Recipient recipient = request.getRecipient();
        Locale locale = recipient.getPreferredLocale();
        ZoneId zone = recipient.getTimeZone();

        Map<String, Object> subCtx = new HashMap<>();
        subCtx.put("planName", subscription.getPlan().getName());
        subCtx.put("planPrice", common.presentMoney(
            subscription.getPlan().getPrice(), 
            subscription.getPlan().getCurrency(), 
            locale));
        subCtx.put("billingPeriod", subscription.getPlan().getBillingPeriod().name().toLowerCase());
        subCtx.put("status", subscription.getStatus().name().toLowerCase());
        
        if (subscription.getCurrentPeriodEnd() != null) {
            subCtx.put("currentPeriodEnd", common.presentDate(
                subscription.getCurrentPeriodEnd(), locale, zone));
            long daysRemaining = ChronoUnit.DAYS.between(
                common.today(zone), subscription.getCurrentPeriodEnd());
            subCtx.put("daysRemaining", Math.max(0, daysRemaining));
        }

        // Plan change details (for upgrade/downgrade)
        if (request.getCategory().contains("upgrade") || request.getCategory().contains("downgrade")) {
            Plan previousPlan = request.getMetadata("previousPlan", Plan.class).orElse(null);
            if (previousPlan != null) {
                subCtx.put("previousPlan", Map.of(
                    "name", previousPlan.getName(),
                    "price", common.presentMoney(previousPlan.getPrice(), previousPlan.getCurrency(), locale)
                ));
            }
        }

        // Cancellation details
        if (request.getCategory().equals("subscription-cancelled")) {
            subCtx.put("cancelReason", request.getMetadata("cancelReason", String.class).orElse(null));
            subCtx.put("feedbackUrl", urlBuilder.subscriptionManageUrl(subscription) + "/feedback");
        }

        return Map.of(
            "category", request.getCategory(),
            "recipient", common.presentRecipient(recipient),
            "subscription", subCtx,
            "actions", Map.of(
                "manageUrl", urlBuilder.subscriptionManageUrl(subscription),
                "upgradeUrl", urlBuilder.subscriptionManageUrl(subscription) + "/upgrade"
            ),
            "flags", Map.of(
                "isExpiring", request.getCategory().equals("subscription-expiring"),
                "isRenewal", request.getCategory().equals("subscription-renewed"),
                "isCancellation", request.getCategory().equals("subscription-cancelled"),
                "isPlanChange", request.getCategory().contains("upgrade") 
                                || request.getCategory().contains("downgrade")
            )
        );
    }
}
```

#### WebhookPresenter.java

```java
@Component
@RequiredArgsConstructor
public class WebhookPresenter implements NotificationPresenter {

    private final ObjectMapper objectMapper;

    @Override
    public Set<String> supportedCategories() {
        return Set.of(
            "webhook-invoice-created",
            "webhook-invoice-paid",
            "webhook-payment-received",
            "webhook-subscription-changed"
        );
    }

    @Override
    public Map<String, Object> present(NotificationRequest request) {
        // Webhooks use a standardized envelope format
        Object payload = request.getPayload(Object.class);
        
        return Map.of(
            "event", Map.of(
                "type", request.getCategory().replace("webhook-", "").replace("-", "."),
                "id", UUID.randomUUID().toString(),
                "created", Instant.now().toString(),
                "apiVersion", "2024-01-01"
            ),
            "data", Map.of(
                "object", payload
            )
        );
    }

    @Override
    public String defaultTemplateSlug(String category) {
        return "webhook-envelope"; // All webhooks share a JSON envelope template
    }
}
```

### Presenter Registry

#### PresenterRegistry.java

```java
@Component
public class PresenterRegistry {

    private final Map<String, NotificationPresenter> presentersByCategory;
    private final NotificationPresenter fallbackPresenter;

    public PresenterRegistry(List<NotificationPresenter> presenters,
                             @Qualifier("genericPresenter") NotificationPresenter fallbackPresenter) {
        this.fallbackPresenter = fallbackPresenter;
        this.presentersByCategory = presenters.stream()
            .flatMap(p -> p.supportedCategories().stream()
                .map(cat -> Map.entry(cat, p)))
            .collect(Collectors.toMap(
                Map.Entry::getKey, 
                Map.Entry::getValue,
                (a, b) -> {
                    throw new IllegalStateException(
                        "Duplicate presenter registration for category");
                }
            ));
    }

    public NotificationPresenter getPresenter(String category) {
        return presentersByCategory.getOrDefault(category, fallbackPresenter);
    }

    public Set<String> getAllCategories() {
        return Collections.unmodifiableSet(presentersByCategory.keySet());
    }

    public boolean hasPresenter(String category) {
        return presentersByCategory.containsKey(category);
    }
}
```

#### GenericPresenter.java

```java
@Component("genericPresenter")
@RequiredArgsConstructor
public class GenericPresenter implements NotificationPresenter {

    private final CommonPresenters common;

    @Override
    public Set<String> supportedCategories() {
        return Set.of(); // Fallback - doesn't claim any categories
    }

    @Override
    public Map<String, Object> present(NotificationRequest request) {
        Recipient recipient = request.getRecipient();
        
        // Minimal context - just pass through the payload
        Map<String, Object> context = new HashMap<>();
        context.put("category", request.getCategory());
        context.put("recipient", common.presentRecipient(recipient));
        context.put("payload", request.getPayload(Object.class));
        context.put("metadata", request.getMetadata());
        
        return context;
    }
}
```

---

## Handlebars Helpers

### HelperRegistry.java

```java
@Component
public class HelperRegistry {

    private final List<NamedHelper> helpers;

    public HelperRegistry(List<NamedHelper> helpers) {
        this.helpers = helpers;
    }

    public void registerAll(Handlebars handlebars) {
        for (NamedHelper helper : helpers) {
            handlebars.registerHelper(helper.name(), helper);
        }
    }
}

public interface NamedHelper extends Helper<Object> {
    String name();
}
```

### DateHelper.java

```java
@Component
public class DateHelper implements NamedHelper {

    private static final Map<String, DateTimeFormatter> FORMATTERS = Map.of(
        "short", DateTimeFormatter.ofPattern("MM/dd/yyyy"),
        "long", DateTimeFormatter.ofPattern("MMMM d, yyyy"),
        "iso", DateTimeFormatter.ISO_LOCAL_DATE,
        "datetime", DateTimeFormatter.ofPattern("MM/dd/yyyy HH:mm"),
        "time", DateTimeFormatter.ofPattern("HH:mm"),
        "relative", DateTimeFormatter.ISO_LOCAL_DATE // Handled specially
    );

    @Override
    public String name() {
        return "formatDate";
    }

    @Override
    public Object apply(Object context, Options options) throws IOException {
        if (context == null) {
            return options.hash("default", "");
        }

        String format = options.hash("format", "short");
        String timezone = options.hash("tz", "UTC");
        String locale = options.hash("locale", "en-US");

        ZoneId zone = ZoneId.of(timezone);
        Locale loc = Locale.forLanguageTag(locale);

        Instant instant = toInstant(context);
        if (instant == null) {
            return context.toString();
        }

        if ("relative".equals(format)) {
            return formatRelative(instant, zone);
        }

        DateTimeFormatter formatter = FORMATTERS.containsKey(format)
            ? FORMATTERS.get(format).withLocale(loc)
            : DateTimeFormatter.ofPattern(format, loc);

        return formatter.format(instant.atZone(zone));
    }

    private String formatRelative(Instant instant, ZoneId zone) {
        LocalDate date = instant.atZone(zone).toLocalDate();
        LocalDate today = LocalDate.now(zone);
        long days = ChronoUnit.DAYS.between(today, date);

        if (days == 0) return "today";
        if (days == 1) return "tomorrow";
        if (days == -1) return "yesterday";
        if (days > 1 && days <= 7) return "in " + days + " days";
        if (days < -1 && days >= -7) return Math.abs(days) + " days ago";
        
        return date.format(DateTimeFormatter.ofPattern("MMM d"));
    }

    private Instant toInstant(Object value) {
        return switch (value) {
            case Instant i -> i;
            case LocalDateTime ldt -> ldt.toInstant(ZoneOffset.UTC);
            case LocalDate ld -> ld.atStartOfDay(ZoneOffset.UTC).toInstant();
            case ZonedDateTime zdt -> zdt.toInstant();
            case Date d -> d.toInstant();
            case Long l -> Instant.ofEpochMilli(l);
            case String s -> tryParse(s);
            default -> null;
        };
    }

    private Instant tryParse(String s) {
        try {
            return Instant.parse(s);
        } catch (DateTimeParseException e) {
            try {
                return LocalDate.parse(s).atStartOfDay(ZoneOffset.UTC).toInstant();
            } catch (DateTimeParseException e2) {
                return null;
            }
        }
    }
}
```

### CurrencyHelper.java

```java
@Component
public class CurrencyHelper implements NamedHelper {

    @Override
    public String name() {
        return "formatCurrency";
    }

    @Override
    public Object apply(Object context, Options options) throws IOException {
        if (context == null) {
            return options.hash("default", "");
        }

        String currencyCode = options.hash("currency", "USD");
        String localeTag = options.hash("locale", "en-US");

        BigDecimal amount = toBigDecimal(context);
        if (amount == null) {
            return context.toString();
        }

        Locale locale = Locale.forLanguageTag(localeTag);
        NumberFormat formatter = NumberFormat.getCurrencyInstance(locale);
        formatter.setCurrency(Currency.getInstance(currencyCode));

        return formatter.format(amount);
    }

    private BigDecimal toBigDecimal(Object value) {
        return switch (value) {
            case BigDecimal bd -> bd;
            case Double d -> BigDecimal.valueOf(d);
            case Float f -> BigDecimal.valueOf(f);
            case Long l -> BigDecimal.valueOf(l);
            case Integer i -> BigDecimal.valueOf(i);
            case String s -> {
                try {
                    yield new BigDecimal(s);
                } catch (NumberFormatException e) {
                    yield null;
                }
            }
            case Number n -> BigDecimal.valueOf(n.doubleValue());
            default -> null;
        };
    }
}
```

### PluralHelper.java

```java
@Component
public class PluralHelper implements NamedHelper {

    @Override
    public String name() {
        return "plural";
    }

    @Override
    public Object apply(Object context, Options options) throws IOException {
        if (context == null) {
            return options.hash("none", options.hash("other", ""));
        }

        int count;
        if (context instanceof Number n) {
            count = n.intValue();
        } else if (context instanceof Collection<?> c) {
            count = c.size();
        } else {
            return options.hash("other", "");
        }

        String template = switch (count) {
            case 0 -> options.hash("none", options.hash("other", ""));
            case 1 -> options.hash("one", "");
            default -> options.hash("other", "");
        };

        return template.replace("{count}", String.valueOf(count))
                       .replace("{}", String.valueOf(count));
    }
}
```

### DefaultHelper.java

```java
@Component
public class DefaultHelper implements NamedHelper {

    @Override
    public String name() {
        return "default";
    }

    @Override
    public Object apply(Object context, Options options) throws IOException {
        if (context == null) {
            return options.param(0, "");
        }
        if (context instanceof String s && s.isBlank()) {
            return options.param(0, "");
        }
        return context;
    }
}
```

### TruncateHelper.java

```java
@Component
public class TruncateHelper implements NamedHelper {

    @Override
    public String name() {
        return "truncate";
    }

    @Override
    public Object apply(Object context, Options options) throws IOException {
        if (context == null) {
            return "";
        }

        String text = context.toString();
        int maxLength = options.hash("length", 100);
        String suffix = options.hash("suffix", "...");

        if (text.length() <= maxLength) {
            return text;
        }

        return text.substring(0, maxLength - suffix.length()) + suffix;
    }
}
```

### ComparisonHelpers.java

```java
@Component
public class ComparisonHelpers {

    @PostConstruct
    public void register(Handlebars handlebars) {
        handlebars.registerHelper("eq", (a, options) -> {
            Object b = options.param(0);
            return Objects.equals(a, b) ? options.fn() : options.inverse();
        });

        handlebars.registerHelper("neq", (a, options) -> {
            Object b = options.param(0);
            return !Objects.equals(a, b) ? options.fn() : options.inverse();
        });

        handlebars.registerHelper("gt", (Helper<Number>) (a, options) -> {
            Number b = options.param(0);
            if (a == null || b == null) return options.inverse();
            return a.doubleValue() > b.doubleValue() ? options.fn() : options.inverse();
        });

        handlebars.registerHelper("gte", (Helper<Number>) (a, options) -> {
            Number b = options.param(0);
            if (a == null || b == null) return options.inverse();
            return a.doubleValue() >= b.doubleValue() ? options.fn() : options.inverse();
        });

        handlebars.registerHelper("lt", (Helper<Number>) (a, options) -> {
            Number b = options.param(0);
            if (a == null || b == null) return options.inverse();
            return a.doubleValue() < b.doubleValue() ? options.fn() : options.inverse();
        });

        handlebars.registerHelper("lte", (Helper<Number>) (a, options) -> {
            Number b = options.param(0);
            if (a == null || b == null) return options.inverse();
            return a.doubleValue() <= b.doubleValue() ? options.fn() : options.inverse();
        });
    }
}
```

---

## Template Rendering Service

### TemplateRenderingService.java

```java
@Service
@RequiredArgsConstructor
@Slf4j
public class TemplateRenderingService {

    private final Handlebars handlebars;
    private final DatabaseTemplateLoader templateLoader;
    private final TemplateRepository templateRepository;
    private final TemplateCategoryMappingRepository mappingRepository;
    private final PresenterRegistry presenterRegistry;

    /**
     * Main entry point: render a notification by category.
     */
    public RenderedNotification render(NotificationRequest request) {
        try {
            DatabaseTemplateLoader.setCurrentUser(request.getUserId());

            // Get presenter and build context
            NotificationPresenter presenter = presenterRegistry.getPresenter(request.getCategory());
            Map<String, Object> context = presenter.present(request);

            // Resolve template: user mapping > default
            String templateSlug = resolveTemplateSlug(request.getUserId(), 
                                                       request.getCategory(), 
                                                       presenter);

            Template templateEntity = templateRepository
                .findByUserIdAndSlug(request.getUserId(), templateSlug)
                .filter(t -> t.getStatus() == TemplateStatus.ACTIVE)
                .filter(Template::hasPublishedVersion)
                .orElseThrow(() -> new TemplateNotFoundException(templateSlug));

            // Compile and render body
            com.github.jknack.handlebars.Template bodyTemplate = 
                handlebars.compile(templateSlug);
            String renderedBody = bodyTemplate.apply(context);

            // Render subject (for email)
            String renderedSubject = null;
            if (templateEntity.getSubjectTemplate() != null) {
                com.github.jknack.handlebars.Template subjectTemplate =
                    handlebars.compileInline(templateEntity.getSubjectTemplate());
                renderedSubject = subjectTemplate.apply(context);
            }

            return RenderedNotification.builder()
                .category(request.getCategory())
                .channel(templateEntity.getChannel())
                .subject(renderedSubject)
                .body(renderedBody)
                .recipientEmail(request.getRecipient().getEmail())
                .templateSlug(templateSlug)
                .templateVersion(templateEntity.getCurrentVersion())
                .build();

        } catch (IOException e) {
            throw new TemplateRenderingException(
                "Failed to render template for category: " + request.getCategory(), e);
        } finally {
            DatabaseTemplateLoader.clearCurrentUser();
        }
    }

    /**
     * Render a draft version for preview purposes.
     */
    public RenderedNotification renderDraft(Long userId, String templateSlug, 
                                            Map<String, Object> sampleContext) {
        Template template = templateRepository.findByUserIdAndSlug(userId, templateSlug)
            .orElseThrow(() -> new TemplateNotFoundException(templateSlug));

        TemplateVersion draft = template.getDraft()
            .orElseThrow(() -> new DraftNotFoundException(templateSlug));

        try {
            DatabaseTemplateLoader.setCurrentUser(userId);

            com.github.jknack.handlebars.Template bodyTemplate =
                handlebars.compileInline(draft.getContent());
            String renderedBody = bodyTemplate.apply(sampleContext);

            String renderedSubject = null;
            if (template.getSubjectTemplate() != null) {
                com.github.jknack.handlebars.Template subjectTemplate =
                    handlebars.compileInline(template.getSubjectTemplate());
                renderedSubject = subjectTemplate.apply(sampleContext);
            }

            return RenderedNotification.builder()
                .category("draft-preview")
                .channel(template.getChannel())
                .subject(renderedSubject)
                .body(renderedBody)
                .templateSlug(templateSlug)
                .templateVersion(0)
                .build();

        } catch (IOException e) {
            throw new TemplateRenderingException("Failed to render draft: " + templateSlug, e);
        } finally {
            DatabaseTemplateLoader.clearCurrentUser();
        }
    }

    /**
     * Validate a template compiles without errors.
     */
    public ValidationResult validateTemplate(String templateContent, 
                                              Map<String, Object> sampleContext) {
        try {
            com.github.jknack.handlebars.Template template = 
                handlebars.compileInline(templateContent);
            template.apply(sampleContext);
            return ValidationResult.valid();
        } catch (HandlebarsException e) {
            return ValidationResult.invalid(e.getMessage(), extractErrorLocation(e));
        } catch (IOException e) {
            return ValidationResult.invalid("IO error: " + e.getMessage(), null);
        }
    }

    private String resolveTemplateSlug(Long userId, String category, 
                                        NotificationPresenter presenter) {
        // Check for user-specific mapping first
        return mappingRepository.findByUserIdAndCategoryCode(userId, category)
            .map(mapping -> {
                Template t = templateRepository.findById(mapping.getTemplateId()).orElse(null);
                return t != null ? t.getSlug() : null;
            })
            .orElseGet(() -> presenter.defaultTemplateSlug(category));
    }

    private ErrorLocation extractErrorLocation(HandlebarsException e) {
        // Parse error message to extract line/column if available
        String message = e.getMessage();
        // Implementation depends on Handlebars error format
        return null;
    }
}
```

### RenderedNotification.java

```java
@Value
@Builder
public class RenderedNotification {
    String category;
    Channel channel;
    @Nullable String subject;
    String body;
    @Nullable String recipientEmail;
    String templateSlug;
    Integer templateVersion;
}
```

### ValidationResult.java

```java
@Value
public class ValidationResult {
    boolean valid;
    @Nullable String errorMessage;
    @Nullable ErrorLocation errorLocation;

    public static ValidationResult valid() {
        return new ValidationResult(true, null, null);
    }

    public static ValidationResult invalid(String message, ErrorLocation location) {
        return new ValidationResult(false, message, location);
    }
}

@Value
public class ErrorLocation {
    int line;
    int column;
}
```

---

## Notification Facade

### NotificationFacade.java

```java
@Service
@RequiredArgsConstructor
@Slf4j
public class NotificationFacade {

    private final TemplateRenderingService renderingService;
    private final EmailSender emailSender;
    private final WebhookSender webhookSender;
    private final SmsSender smsSender;
    private final NotificationRepository notificationRepository;

    @Transactional
    public NotificationResult send(NotificationRequest request) {
        log.info("Sending notification: category={}, userId={}, recipient={}",
            request.getCategory(), request.getUserId(), request.getRecipient().getEmail());

        try {
            // Render the template
            RenderedNotification rendered = renderingService.render(request);

            // Dispatch based on channel
            DeliveryResult delivery = switch (rendered.getChannel()) {
                case EMAIL -> emailSender.send(
                    rendered.getRecipientEmail(),
                    rendered.getSubject(),
                    rendered.getBody()
                );
                case WEBHOOK -> webhookSender.send(
                    request.getMetadata("webhookUrl", String.class).orElseThrow(),
                    rendered.getBody()
                );
                case SMS -> smsSender.send(
                    request.getRecipient().getPhone(),
                    rendered.getBody()
                );
            };

            // Record the notification
            Notification notification = Notification.builder()
                .userId(request.getUserId())
                .category(request.getCategory())
                .channel(rendered.getChannel())
                .recipientEmail(rendered.getRecipientEmail())
                .subject(rendered.getSubject())
                .templateSlug(rendered.getTemplateSlug())
                .templateVersion(rendered.getTemplateVersion())
                .status(delivery.isSuccess() ? NotificationStatus.SENT : NotificationStatus.FAILED)
                .externalId(delivery.getExternalId())
                .errorMessage(delivery.getErrorMessage())
                .sentAt(Instant.now())
                .build();

            notificationRepository.save(notification);

            return NotificationResult.success(notification.getId(), delivery.getExternalId());

        } catch (TemplateNotFoundException e) {
            log.error("Template not found for category: {}", request.getCategory(), e);
            return NotificationResult.failure("TEMPLATE_NOT_FOUND", e.getMessage());
        } catch (TemplateRenderingException e) {
            log.error("Template rendering failed for category: {}", request.getCategory(), e);
            return NotificationResult.failure("RENDERING_ERROR", e.getMessage());
        } catch (Exception e) {
            log.error("Notification sending failed for category: {}", request.getCategory(), e);
            return NotificationResult.failure("SEND_ERROR", e.getMessage());
        }
    }
}
```

---

## Example Templates

### invoice-due-reminder.hbs

```handlebars
{{> email-header}}

<h1>Invoice {{invoice.number}} Payment Reminder</h1>

<p>Hi {{recipient.firstName}},</p>

{{#if flags.isReminder}}
<p>This is a friendly reminder that your invoice 
<strong>{{invoice.number}}</strong> for 
<strong>{{invoice.total.formatted}}</strong> is due 
{{formatDate invoice.dueDate.raw format="relative" tz=recipient.timezone}}.</p>
{{/if}}

{{#if invoice.isOverdue}}
<div class="alert alert-warning">
  <p>⚠️ This invoice is <strong>{{invoice.daysOverdue}} days overdue</strong>.</p>
  {{#if flags.showLateFeeWarning}}
  <p>A late fee of {{invoice.lateFee.formatted}} may be applied.</p>
  {{/if}}
</div>
{{/if}}

{{#if flags.showLineItems}}
<h2>Invoice Details</h2>
<table class="invoice-table">
  <thead>
    <tr>
      <th>Description</th>
      <th>Qty</th>
      <th>Amount</th>
    </tr>
  </thead>
  <tbody>
    {{#each invoice.lineItems}}
    <tr>
      <td>{{description}}</td>
      <td>{{quantity}}</td>
      <td>{{amount.formatted}}</td>
    </tr>
    {{/each}}
  </tbody>
  <tfoot>
    <tr>
      <td colspan="2"><strong>Total</strong></td>
      <td><strong>{{invoice.total.formatted}}</strong></td>
    </tr>
    {{#if invoice.isPartiallyPaid}}
    <tr>
      <td colspan="2">Amount Paid</td>
      <td>{{invoice.amountPaid.formatted}}</td>
    </tr>
    <tr>
      <td colspan="2"><strong>Amount Due</strong></td>
      <td><strong>{{invoice.amountDue.formatted}}</strong></td>
    </tr>
    {{/if}}
  </tfoot>
</table>
{{/if}}

{{#if actions.canPay}}
<p style="text-align: center; margin: 30px 0;">
  <a href="{{actions.payUrl}}" class="btn btn-primary">Pay Now</a>
</p>
{{/if}}

<p>
  <a href="{{actions.viewUrl}}">View Invoice</a>
  {{#if actions.canDispute}} | <a href="{{actions.disputeUrl}}">Dispute Invoice</a>{{/if}}
  | <a href="{{actions.pdfUrl}}">Download PDF</a>
</p>

{{> email-footer}}
```

### email-header.hbs (partial)

```handlebars
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{subject}}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
    .btn { display: inline-block; padding: 12px 24px; border-radius: 4px; text-decoration: none; }
    .btn-primary { background: #0066cc; color: white; }
    .alert { padding: 16px; border-radius: 4px; margin: 16px 0; }
    .alert-warning { background: #fff3cd; border: 1px solid #ffc107; }
    .invoice-table { width: 100%; border-collapse: collapse; }
    .invoice-table th, .invoice-table td { padding: 8px; border-bottom: 1px solid #eee; }
  </style>
</head>
<body>
<div class="container" style="max-width: 600px; margin: 0 auto; padding: 20px;">

{{#if company.logo}}
<img src="{{company.logo}}" alt="{{company.name}}" style="max-height: 50px; margin-bottom: 20px;">
{{else}}
<h2 style="margin-bottom: 20px;">{{company.name}}</h2>
{{/if}}
```

### email-footer.hbs (partial)

```handlebars
<hr style="margin: 40px 0 20px; border: none; border-top: 1px solid #eee;">

<p style="font-size: 12px; color: #666;">
  {{company.name}}<br>
  {{company.address.formatted}}<br>
  {{company.email}}
</p>

<p style="font-size: 11px; color: #999;">
  You're receiving this email because you have an account with {{company.name}}.
  <a href="{{unsubscribeUrl}}">Unsubscribe</a>
</p>

</div>
</body>
</html>
```

### webhook-envelope.hbs

```handlebars
{
  "event": {
    "type": "{{event.type}}",
    "id": "{{event.id}}",
    "created": "{{event.created}}",
    "api_version": "{{event.apiVersion}}"
  },
  "data": {{{json data.object}}}
}
```

---

## Component Summary

| Component | Responsibility |
|-----------|---------------|
| **Database Schema** | Templates, versions, categories, mappings |
| **Template / TemplateVersion** | JPA entities for versioned templates |
| **DatabaseTemplateLoader** | Handlebars loader resolving slugs from DB with caching |
| **NotificationPresenter** | Interface for category-specific context builders |
| **CommonPresenters** | Shared formatting: recipient, money, dates, addresses |
| **Category Presenters** | Business logic per category group (Invoice, Payment, etc.) |
| **PresenterRegistry** | Routes category → presenter |
| **HelperRegistry + Helpers** | Handlebars helpers for formatting in templates |
| **TemplateRenderingService** | Orchestrates presenter → template → rendered output |
| **NotificationFacade** | Entry point: render + dispatch + record |

---

## Category to Presenter Mapping

| Category Group | Presenter | Categories (~count) |
|----------------|-----------|---------------------|
| Invoice | InvoicePresenter | 10 |
| Payment | PaymentPresenter | 6 |
| Account | AccountPresenter | 7 |
| Subscription | SubscriptionPresenter | 7 |
| Webhook | WebhookPresenter | 4+ |
| Generic | GenericPresenter | fallback |

With ~25 presenter classes covering 100 categories, each presenter handles 4-10 related categories, sharing 80% of the logic while branching for category-specific differences.
