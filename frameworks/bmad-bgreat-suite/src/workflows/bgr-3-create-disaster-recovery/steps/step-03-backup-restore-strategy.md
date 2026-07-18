# Step 3: Backup & Restore Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on designing backup procedures, restore testing, and data protection
- 🎯 BUILD on the RTO/RPO targets and service classification from step 2
- ⚠️ Do not estimate software delivery timelines or task durations — but do define DR operational timing (backup cadence, RTO/RPO targets, failover time targets, drill schedules) as these are core DR plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ⚠️ Present C/R menu after generating backup and restore strategy
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the strategy, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with service classification and RTO/RPO targets from step 2 is available
- Architecture and infrastructure context are loaded
- Focus on how to protect data and how to restore it within RPO/RTO targets
- Build on the criticality tiers to define appropriate backup strategies per tier

## YOUR TASK:

Design comprehensive backup procedures, restore testing cadence, data protection policies, and geographic replication strategies aligned with the RTO/RPO targets defined in step 2.

## BACKUP & RESTORE STRATEGY SEQUENCE:

### 1. Inventory Data Stores

For each data store identified in the architecture:

**Database Systems:**
- Type: Relational (PostgreSQL, MySQL), Document (MongoDB, DynamoDB), Graph, Time-series
- Size: Current and projected growth
- Transaction volume: Writes per second, peak vs steady-state
- Criticality tier: From step 2 classification
- Current backup approach (if any)

**Object Storage:**
- Buckets and their purposes
- Data volume and growth rate
- Access patterns (hot, warm, cold)
- Versioning and lifecycle policies

**Message Queues and Event Stores:**
- Broker type (Kafka, RabbitMQ, SQS)
- Retention requirements
- Replay capabilities
- Consumer offset management

**Configuration and Secrets:**
- IaC state files (Terraform state, CloudFormation)
- Application configuration
- Secrets and certificates
- DNS records and routing rules

### 2. Define Backup Procedures per Tier

For each criticality tier, define backup strategy:

**Tier 1 — Mission Critical:**
- **Method**: Continuous replication (synchronous or near-synchronous)
- **Frequency**: Real-time / sub-minute
- **Replication**: Multi-region with automatic failover
- **Point-in-time recovery**: Continuous with sub-minute granularity
- **Retention**: Minimum 30 days point-in-time, 1 year snapshots
- **Encryption**: At rest and in transit, customer-managed keys

**Tier 2 — Business Critical:**
- **Method**: Asynchronous replication + periodic snapshots
- **Frequency**: Every 15 minutes (snapshots), continuous (replication lag < RPO)
- **Replication**: Cross-region standby
- **Point-in-time recovery**: 15-minute granularity
- **Retention**: 30 days point-in-time, 6 months snapshots
- **Encryption**: At rest and in transit

**Tier 3 — Business Important:**
- **Method**: Scheduled snapshots + transaction log backups
- **Frequency**: Hourly snapshots, continuous transaction logs
- **Replication**: Cross-AZ within same region
- **Point-in-time recovery**: 1-hour granularity
- **Retention**: 14 days snapshots, 3 months archives
- **Encryption**: At rest

**Tier 4 — Non-Critical:**
- **Method**: Daily snapshots
- **Frequency**: Once per day during low-traffic window
- **Replication**: Same region, different AZ
- **Point-in-time recovery**: Daily granularity
- **Retention**: 7 days snapshots, 1 month archives
- **Encryption**: At rest

Present these as starting recommendations and adjust based on user context.

### 3. Design Geographic Replication Strategy

Based on infrastructure topology and cloud provider:

**Replication Topology:**
- Primary region and DR region(s)
- Active-active vs active-passive vs pilot light vs backup-restore
- Data consistency model: Strong consistency vs eventual consistency
- Replication lag monitoring and alerting

**Cross-Region Data Sync:**
- Database replication method (native replication, DMS, custom)
- Object storage replication (S3 CRR, GCS multi-region, Azure GRS)
- Message queue mirroring strategy
- Configuration sync across regions

**Network Considerations:**
- DNS failover configuration (Route 53, Cloud DNS)
- Global load balancer setup
- VPN or private connectivity between regions
- Certificate management for DR endpoints

### 4. Define Restore Testing Cadence

Establish a regular restore testing schedule:

**Testing Types:**

| Test Type | Frequency | Scope | Success Criteria | Owner |
|-----------|-----------|-------|------------------|-------|
| Backup verification | Daily (automated) | All backups | Backup completed, checksum valid, size within expected range | {SRE on-call} |
| Point-in-time restore | Monthly | Tier 1 & 2 databases | Data restored to target timestamp, application validates successfully | {DB Platform Team} |
| Full-service restore | Quarterly | One Tier 1 service end-to-end | Service operational within RTO, data loss within RPO | {Service Owner + SRE} |
| Full DR drill | Annually | Complete DR region activation | All Tier 1 & 2 services operational in DR region within targets | {Incident Commander} |

**Testing Procedures:**
- Restore to isolated environment (never to production)
- Validate data integrity after restore (checksums, row counts, application-level validation)
- Measure actual restore time vs RTO targets
- Document findings and update procedures
- Track restore time trends over time

**Test Result Tracking:**
- Record results in a shared DR test log
- Alert on backup verification failures
- Escalate restore time regression (getting slower)
- Report quarterly to leadership

### 5. Define Data Protection Policies

**Immutability and Tamper Protection:**
- Object lock / WORM policies for compliance-critical data
- Backup encryption key management and rotation
- Separation of duties: backup operators vs restore operators
- Audit logging for all backup and restore operations

**Compliance Considerations:**
- Data residency requirements (where can backups be stored?)
- Retention requirements by regulation (GDPR, SOX, HIPAA, PCI-DSS)
- Right to erasure: How to delete specific data from backups
- Cross-border data transfer restrictions

**Backup Security:**
- Encryption at rest with customer-managed keys
- Encryption in transit for replication
- Access controls: Principle of least privilege for backup operations
- Ransomware protection: Air-gapped or immutable backup copies
- Regular audit of backup access logs

### 6. Present Strategy

Reflect the backup and restore strategy back to the user:

"Here's the Backup & Restore Strategy for {{project_name}}.

**Data Store Inventory:**
- {count} data stores inventoried across {count} services
- {count} databases, {count} object stores, {count} message queues

**Backup Strategy by Tier:**
{summary table of backup frequency, method, and retention per tier}

**Geographic Replication:**
- DR topology: {active-active / active-passive / pilot light}
- Primary: {region}, DR: {region}
- Replication method: {summary}

**Restore Testing:**
- Daily automated verification
- Monthly point-in-time restore tests
- Quarterly full-service restore
- Annual full DR drill

**Data Protection:**
- Encryption: {summary}
- Compliance: {requirements noted}
- Immutability: {approach}

Does this strategy align with your requirements? Anything to adjust?"

### 7. Generate Backup & Restore Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 4. Backup & Restore Strategy

### Data Store Inventory

| Data Store | Type | Service | Tier | Size | Growth Rate | Current Backup |
|-----------|------|---------|------|------|-------------|----------------|
{{data_store_inventory_entries}}

### Backup Procedures

| Tier | Method | Frequency | Replication | PITR Granularity | Retention | Encryption |
|------|--------|-----------|-------------|------------------|-----------|------------|
{{backup_procedures_per_tier}}

### Per-Service Backup Configuration

| Service | Data Store | Backup Method | Schedule | Target Region | RPO Met? |
|---------|-----------|---------------|----------|---------------|----------|
{{per_service_backup_configuration}}

### Geographic Replication

#### Replication Topology

{{replication_topology_description}}

#### Cross-Region Data Sync

| Data Store | Replication Method | Consistency Model | Lag Target | Monitoring |
|-----------|-------------------|-------------------|------------|------------|
{{cross_region_sync_entries}}

### Restore Testing

| Test Type | Frequency | Scope | Success Criteria | Owner |
|-----------|-----------|-------|------------------|-------|
{{restore_testing_schedule}}

### Testing Procedures

{{detailed_testing_procedures}}

### Data Protection Policies

#### Encryption & Access Control

{{encryption_and_access_policies}}

#### Compliance Requirements

{{compliance_requirements}}

#### Immutability & Tamper Protection

{{immutability_policies}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Backup & Restore Strategy covering data protection, geographic replication, and restore testing.

**Here's what I'll add to the disaster recovery plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this strategy and proceed to failover procedures
[R] Revise - Let's discuss changes before saving"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/disaster-recovery-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-failover-procedures.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ All data stores inventoried with type, size, and criticality
✅ Backup procedures defined per tier aligned with RPO targets
✅ Geographic replication strategy designed with consistency model
✅ Restore testing cadence established with clear success criteria
✅ Data protection policies defined covering encryption, compliance, immutability
✅ Per-service backup configuration mapped
✅ User confirmation of strategy
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining backup strategy without aligning to RPO targets from step 2
❌ Not inventorying all data stores from the architecture
❌ Skipping restore testing cadence
❌ Not addressing compliance and data residency requirements
❌ Not considering ransomware protection and immutability
❌ Not validating strategy with user
❌ Generating content without building on step 2 targets

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-04-failover-procedures.md` to define geographic failover strategies, DR runbooks, and communication procedures.

Remember: Do NOT proceed to step-04 until user explicitly selects 'C' from the C/R menu and content is saved!
