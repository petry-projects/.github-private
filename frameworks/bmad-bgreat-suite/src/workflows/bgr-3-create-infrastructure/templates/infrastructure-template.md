---
status: draft
stepsCompleted: []
inputDocuments: []
createdDate: ""
lastUpdated: ""
---

# Infrastructure Plan

## 1. Overview

- **Project**:
- **Author**:
- **Cloud Provider**:
- **Maturity Level**:

## 2. Infrastructure as Code

### 2.1 Tool Selection

| Tool | Purpose | Version | Notes |
|------|---------|---------|-------|

### 2.2 State Management
### 2.3 Module Strategy
### 2.4 Policy as Code
### 2.5 Drift Detection

## 3. Environment Strategy

### 3.1 Environment Topology

| Environment | Purpose | Scale | Data | Auto-Shutdown | Cloud Account/Subscription |
|-------------|---------|-------|------|---------------|---------------------------|

### 3.2 Environment Isolation

**Account Separation:**

**Network Isolation:**

**Secrets Isolation:**

**IAM Isolation:**

**State Isolation:**

### 3.3 Environment Parity Rules
### 3.4 Configuration Management
### 3.5 Secrets Management

### 3.6 Promotion Gates & Change Control

**Environment Promotion Flow:**

**Gate Requirements per Boundary:**

**Signoff Requirements:**

**No-Bypass Enforcement:**

### 3.7 Cost Management

## 4. Network Architecture

### 4.1 VPC/VNet Design
### 4.2 Subnet Strategy
### 4.3 DNS & Load Balancing

## 5. Container Strategy

### 5.1 Runtime Selection
### 5.2 Cluster Architecture
### 5.3 Image Strategy
### 5.4 Security
### 5.5 Service Mesh

## 6. Cost Estimation per Environment

| Environment | Compute | Storage | Network | Managed Services | Total Monthly (Est.) |
|-------------|---------|---------|---------|-------------------|---------------------|

### 6.1 Cost Breakdown

- **Production**:
- **Staging**:
- **Development**:
- **Shared services (CI runners, registries, DNS)**:
- **Total estimated monthly cost**:
- **Total estimated annual cost**:

### 6.2 Cost Optimization Strategies

- Reserved instances / savings plans:
- Auto-scaling to zero for non-prod:
- Spot / preemptible instances for workloads:
- Right-sizing review cadence:

## 7. Migration Strategy

> Complete this section if migrating from existing infrastructure (brownfield). Remove if greenfield.

### 7.1 Current State Inventory

| Resource | Current Platform | Current Config | Migration Complexity | Notes |
|----------|-----------------|---------------|---------------------|-------|

### 7.2 Migration Approach

- **Strategy**: Lift-and-shift / Re-platform / Re-architect / Hybrid
- **Migration tooling**:
- **Data migration plan**:
- **DNS / traffic cutover plan**:

### 7.3 Migration Phases

| Phase | Scope | Rollback Plan | Validation Criteria | Target Date |
|-------|-------|--------------|---------------------|-------------|

### 7.4 Risk Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|

## 8. Decision Rationale for IaC Tool Selection

### 8.1 Tool Evaluation Matrix

| Criterion | Weight | {Tool A} | {Tool B} | {Tool C} | Notes |
|-----------|--------|----------|----------|----------|-------|
| Multi-cloud support | | | | | |
| Team familiarity | | | | | |
| Ecosystem & modules | | | | | |
| State management | | | | | |
| Testing & validation | | | | | |
| Community & support | | | | | |
| Cost | | | | | |

### 8.2 Architecture Decision Record

- **Decision**: Use {chosen_tool} as primary IaC tool
- **Context**: What problem does this solve?
- **Alternatives considered**:
- **Consequences**: What trade-offs are accepted?
- **Review date**:

## 9. Security Baseline Requirements

### 9.1 Identity & Access

- **IAM strategy**: Least privilege / role-based
- **Service account management**:
- **Credential rotation policy**:
- **MFA requirements**:

### 9.2 Network Security

- **Default deny posture**: yes / no
- **Ingress/egress rules**:
- **WAF / DDoS protection**:
- **Private connectivity (VPN / PrivateLink)**:

### 9.3 Data Protection

- **Encryption at rest**: Required for all environments / production only
- **Encryption in transit**: TLS version minimum
- **Key management**: KMS / Vault / provider-native
- **Backup encryption**:

### 9.4 Compliance & Governance

- **Compliance frameworks**: (SOC 2, HIPAA, PCI-DSS, etc.)
- **Tagging policy enforcement**:
- **Audit logging**: CloudTrail / Activity Log / equivalent
- **Policy-as-code enforcement**:

### 9.5 Vulnerability Management

- **Image scanning**: Pre-deploy / runtime
- **OS patching cadence**:
- **Dependency scanning**:

## 10. Implementation Sequence

| Phase | Description | Dependencies | Owner |
|-------|-------------|-------------|-------|
