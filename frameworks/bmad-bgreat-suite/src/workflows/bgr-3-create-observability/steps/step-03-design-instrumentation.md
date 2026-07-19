# Step 3: Instrumentation Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on designing future-state observability instrumentation
- 🎯 BUILD on the current state assessment from step 2
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present C/R menu after generating instrumentation design
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the design, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with Current State Assessment from step 2 is available
- Architecture decisions and infrastructure context are loaded
- Gaps identified in step 2 drive the instrumentation design
- Focus on what to measure, how to log, and how to trace

## YOUR TASK:

Design the future-state observability instrumentation strategy covering metrics taxonomy, structured logging standards, distributed tracing design, and event schemas.

## INSTRUMENTATION DESIGN SEQUENCE:

### 1. Define Metrics Taxonomy

Work with the user to establish the metrics strategy:

**Golden Signals per Service:**

For each service identified in the architecture, define:
- **Latency**: What to measure (p50, p95, p99), collection method, meaningful thresholds
- **Traffic**: Request rate, throughput metrics, segmentation dimensions
- **Errors**: Error classification (client vs server, by type), error rate calculation
- **Saturation**: Resource utilization metrics, queue depths, connection pool usage

**Methodology Selection:**

Discuss and choose the appropriate approach per service type:
- **RED method** (Rate, Errors, Duration) — for request-driven services (APIs, web frontends)
- **USE method** (Utilization, Saturation, Errors) — for resource-oriented components (databases, caches, queues)

Present the trade-offs and let the user decide per service category.

**Reliability Metrics:**
- Mean Time to Detect (MTTD)
- Mean Time to Resolve (MTTR)
- Change failure rate
- Deployment frequency impact on reliability

**Business KPIs:**
- Revenue-impacting metrics (transactions per minute, conversion rate)
- User experience metrics (page load time, interaction latency)
- Feature adoption and usage metrics
- Session health indicators

**Resource Metrics:**
- CPU, memory, disk, network per service
- Container/pod resource consumption
- Database connection pool utilization
- Queue depth and processing lag

### 2. Design Structured Logging Standards

Collaborate on logging conventions:

**Log Format:**
- JSON structured format for machine parseability
- Human-readable fallback for local development
- Consistent schema across all services

**Required Fields (every log entry):**
- `timestamp` — ISO 8601 with timezone
- `level` — TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- `service` — Service name identifier
- `request_id` — Unique request correlation ID
- `trace_id` — Distributed tracing correlation
- `span_id` — Current span identifier
- `message` — Human-readable log message

**Contextual Fields (when applicable):**
- `user_id` — Authenticated user (hashed if PII policy requires)
- `endpoint` — API endpoint or operation
- `duration_ms` — Operation duration
- `status_code` — HTTP or gRPC status
- `error_type` — Error classification
- `error_stack` — Stack trace (ERROR/FATAL only)

**PII Redaction Policy:**
- Define what constitutes PII in the project context
- Redact or hash at the source, never in the pipeline
- Audit logging exceptions (compliance requirements)
- Automated PII detection rules

**Log Level Guidelines:**
- TRACE: Detailed diagnostic, development only
- DEBUG: Diagnostic information, disabled in production by default
- INFO: Normal operational events, request lifecycle
- WARN: Unexpected but recoverable conditions
- ERROR: Failures requiring attention
- FATAL: Unrecoverable failures, service shutdown

**Retention Policy:**
- Hot storage: {discuss duration — typically 7-30 days}
- Warm storage: {discuss duration — typically 30-90 days}
- Cold/archive: {discuss duration — compliance driven}
- Deletion policy aligned with data governance

### 3. Design Distributed Tracing Strategy

Collaborate on tracing conventions:

**Instrumentation Approach:**
- OpenTelemetry SDK as the standard instrumentation library
- Auto-instrumentation for supported frameworks
- Manual instrumentation for business-critical paths
- Vendor-agnostic export (OTLP protocol)

**Span Naming Convention:**
- Format: `{service}.{operation}` (e.g., `order-service.createOrder`)
- HTTP spans: `{service}.{method} {route}` (e.g., `api-gateway.GET /orders/{id}`)
- Database spans: `{service}.db.{operation}` (e.g., `order-service.db.query`)
- Queue spans: `{service}.queue.{operation}` (e.g., `notification-service.queue.publish`)

**Key Span Attributes:**
- `service.name` — Service identifier
- `service.version` — Deployed version
- `deployment.environment` — Environment name
- `user.id` — User identifier (hashed if needed)
- `order.id`, `session.id` — Business correlation IDs
- `http.method`, `http.route`, `http.status_code` — HTTP context
- `db.system`, `db.statement` — Database context (sanitized)

**Sampling Strategy:**
- Head-based sampling for routine traffic (discuss rate — typically 1-10%)
- Tail-based sampling for errors and high-latency requests (100%)
- Always sample for specific business-critical operations
- Adaptive sampling during incidents (increase to 100%)

**Cardinality Controls:**
- Limit unique label/attribute values to prevent storage explosion
- Use route templates, not actual URLs (avoid query parameters)
- Bound user-generated values (truncate, hash, or drop)
- Monitor cardinality growth with alerts

### 4. Design Event Schemas

Define schemas for business-critical events:

**Event Categories:**
- **System events**: Service start/stop, deployment, configuration change
- **Business events**: Order placed, payment processed, user signup
- **Security events**: Authentication, authorization, access denied
- **Operational events**: Scaling, failover, backup completion

**Event Schema Standard:**
- Consistent envelope: `{event_type, timestamp, source, correlation_id, payload}`
- Versioned schemas for backward compatibility
- Dead letter queue for malformed events

### 5. Present Design

Reflect the instrumentation design back to the user:

"Here's the instrumentation strategy I've drafted for {{project_name}}.

**Metrics Approach:**
- Methodology: {RED/USE per service type}
- Golden Signals: Defined for {N} services
- Business KPIs: {count} metrics identified
- Reliability metrics: MTTD, MTTR, change failure rate

**Logging Standards:**
- Format: JSON structured
- Required fields: {count} standard fields
- PII handling: {redaction approach}
- Retention: {hot/warm/cold durations}

**Tracing Design:**
- Instrumentation: OpenTelemetry
- Span naming: {service}.{operation}
- Sampling: {strategy summary}
- Cardinality controls: {approach}

Does this cover your needs? Anything to adjust or add?"

### 6. Generate Instrumentation Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 3. Metrics Strategy

| Service | Signal | Metric Name | Collection Method | Retention | Notes |
|---------|--------|-------------|-------------------|-----------|-------|
{{metrics_table_entries}}

### 3.1 Golden Signals per Service

{{golden_signals_definitions_per_service}}

### 3.2 Business KPIs

{{business_kpi_metrics}}

### 3.3 Resource Metrics

{{resource_metrics_definitions}}

## 4. Logging Strategy

- **Format**: JSON structured logging
- **Key Fields**: {{required_and_contextual_fields}}
- **PII Handling**: {{pii_redaction_policy}}
- **Retention Policy**: {{hot_warm_cold_durations}}
- **Correlation**: {{request_id_and_trace_id_linking}}

### Log Level Guidelines

{{log_level_definitions_and_usage}}

## 5. Tracing Strategy

- **Instrumentation**: OpenTelemetry SDK with auto-instrumentation
- **Span Naming Convention**: `{service}.{operation}`
- **Key Attributes**: {{span_attribute_definitions}}
- **Sampling Strategy**: {{sampling_approach_details}}

### Cardinality Controls

{{cardinality_management_rules}}

### Event Schemas

{{event_category_definitions_and_schemas}}
```

### 7. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Instrumentation Strategy covering metrics, logging, tracing, and event schemas.

**Here's what I'll add to the observability plan:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save this design and proceed to SLO & alerting framework
[R] Revise - Let's discuss changes before saving"

### 8. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/observability.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-slo-alert-framework.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ Metrics taxonomy defined with Golden Signals per service
✅ RED/USE methodology chosen and applied appropriately
✅ Structured logging standards fully specified
✅ PII handling policy defined with redaction approach
✅ Distributed tracing designed with OpenTelemetry conventions
✅ Sampling strategy and cardinality controls established
✅ Event schemas defined for business-critical events
✅ User confirmation of instrumentation design
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Designing metrics without aligning to Golden Signals
❌ Skipping PII considerations in logging standards
❌ Not addressing cardinality explosion risks in tracing
❌ Choosing sampling strategy without discussing trade-offs
❌ Not validating instrumentation design with user
❌ Generating content without building on step 2 gaps

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-04-slo-alert-framework.md` to define SLOs, error budgets, and alerting strategy.

Remember: Do NOT proceed to step-04 until user explicitly selects 'C' from the C/R menu and content is saved!
