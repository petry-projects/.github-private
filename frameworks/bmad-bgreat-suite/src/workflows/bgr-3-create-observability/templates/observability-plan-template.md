---
status: draft
stepsCompleted: []
inputDocuments: []
createdDate: ""
lastUpdated: ""
---

# Observability Plan

## 1. Overview

- **Project**:
- **Author**:
- **Objectives**:

## 2. Current State Summary

## 3. Metrics Strategy

| Service | Signal | Metric Name | Collection Method | Retention | Notes |
|---------|--------|-------------|-------------------|-----------|-------|

### 3.1 Golden Signals per Service
### 3.2 Business KPIs
### 3.3 Resource Metrics

## 4. Logging Strategy

- **Format**:
- **Key Fields**:
- **PII Handling**:
- **Retention Policy**:
- **Correlation**:

## 5. Tracing Strategy

- **Instrumentation**:
- **Span Naming Convention**:
- **Key Attributes**:
- **Sampling Strategy**:

## 6. SLOs & Error Budgets

| User Journey | SLI | Target | Window | Alert Threshold | Notes |
|-------------|-----|--------|--------|-----------------|-------|

## 7. Alerting Strategy

| Alert Name | Trigger | Severity | Channel | Runbook | Notes |
|-----------|---------|----------|---------|---------|-------|

### 7.1 Alert Routing & Escalation
### 7.2 Noise Reduction

## 8. Dashboard Requirements

| Dashboard | Audience | Key Metrics | Refresh | Owner |
|-----------|----------|-------------|---------|-------|

## 9. Cost Estimation

| Component | Tool/Service | Tier | Monthly Cost (Est.) | Annual Cost (Est.) | Notes |
|-----------|-------------|------|---------------------|--------------------|-------|

### 9.1 Cost Breakdown by Category

- **Metrics ingestion & storage**:
- **Log ingestion & storage**:
- **Trace ingestion & storage**:
- **Dashboard / visualization licensing**:
- **Alerting / on-call tooling**:
- **Total estimated monthly cost**:
- **Cost per service / per environment**:

### 9.2 Cost Optimization Strategies

- Sampling and retention tuning:
- Tiered storage (hot/warm/cold):
- Reserved capacity or committed-use discounts:

## 10. Decision Rationale

### 10.1 Tool Selection Rationale

| Category | Chosen Tool | Alternatives Evaluated | Key Deciding Factors |
|----------|-------------|----------------------|---------------------|

### 10.2 Architecture Decision Records

- **Metrics backend**: Why {chosen} over {alternative}?
- **Logging backend**: Why {chosen} over {alternative}?
- **Tracing backend**: Why {chosen} over {alternative}?
- **Alerting platform**: Why {chosen} over {alternative}?

### 10.3 Trade-Off Summary

| Decision | Benefit Gained | Trade-Off Accepted |
|----------|---------------|-------------------|

## 11. Team Skill Assessment & Training Needs

### 11.1 Current Team Skills

| Skill Area | Current Level (1-5) | Required Level | Gap | Notes |
|------------|---------------------|----------------|-----|-------|
| Metrics & dashboarding | | | | |
| Structured logging | | | | |
| Distributed tracing | | | | |
| SLO/SLI definition | | | | |
| Alert tuning & on-call | | | | |
| Incident analysis | | | | |

### 11.2 Training Plan

| Topic | Format | Provider / Resource | Target Completion | Audience |
|-------|--------|--------------------|--------------------|----------|

### 11.3 Knowledge Transfer Strategy

- Pairing / shadowing plan:
- Documentation ownership:
- Runbook review cadence:

## 12. Quick Reference Card

> **One-page checklist for on-call and operations teams.**

### Key Dashboards

| Dashboard | URL | When to Use |
|-----------|-----|-------------|

### Key Alerts & Escalation

| Alert | Severity | First Responder Action | Escalation Path |
|-------|----------|----------------------|----------------|

### Key SLOs

| Service / Journey | SLO Target | Current Status | Error Budget Remaining |
|-------------------|-----------|---------------|----------------------|

### Emergency Contacts

| Role | Name | Contact | Backup |
|------|------|---------|--------|

### Common Troubleshooting Commands

```text
# Placeholder — fill in with environment-specific commands
```

## 13. Implementation Roadmap

| Milestone | Description | Owner | Target Date |
|-----------|-------------|-------|-------------|
