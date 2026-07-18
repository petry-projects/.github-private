---
status: draft
stepsCompleted: []
inputDocuments: []
createdDate: ""
lastUpdated: ""
---

# Incident Response Plan

## 1. Overview

- **Project**:
- **Author**:
- **Last Review Date**:

## 2. Severity Classification

| Level | Criteria | Response Time | Communication | Escalation |
|-------|----------|---------------|---------------|------------|
| SEV1 | | | | |
| SEV2 | | | | |
| SEV3 | | | | |
| SEV4 | | | | |

## 3. Escalation Matrix

## 4. On-Call Procedures

### 4.1 Rotation Schedule
### 4.2 Handoff Protocol
### 4.3 Fatigue Management

## 5. Response Workflow

### 5.1 Detection & Triage

### 5.2 Communication Templates

#### 5.2.1 Initial Notification

> **Subject**: [SEV{X}] {service} — {brief description}
>
> **Status**: Investigating / Identified / Monitoring / Resolved
>
> **Impact**: {who is affected, what is broken}
>
> **Current Actions**: {what the team is doing right now}
>
> **Next Update**: {time of next update}
>
> **Incident Lead**: {name}

#### 5.2.2 Stakeholder Status Update

> **Subject**: [UPDATE {N}] [SEV{X}] {service} — {brief description}
>
> **Status**: {current status}
>
> **Summary since last update**: {what changed}
>
> **Customer impact**: {current impact scope and duration}
>
> **ETA to resolution**: {estimated or unknown}
>
> **Next update in**: {time interval}

#### 5.2.3 Resolution Notification

> **Subject**: [RESOLVED] [SEV{X}] {service} — {brief description}
>
> **Duration**: {start time} to {end time} ({total duration})
>
> **Root Cause**: {one-line summary}
>
> **Impact Summary**: {users affected, SLO budget consumed}
>
> **Postmortem**: {scheduled / not required} — {date if scheduled}
>
> **Follow-up Actions**: {key items}

#### 5.2.4 External / Customer Communication

> We are aware of an issue affecting {feature/service}. Our engineering team is actively working on a resolution. We will provide updates every {interval}. We apologize for the inconvenience.

### 5.3 Escalation Decision Trees

#### 5.3.1 Severity Escalation Flowchart

```text
Incident Detected
  |
  v
Is customer-facing impact confirmed?
  |-- YES --> Is revenue or data integrity at risk?
  |             |-- YES --> SEV1: Page Incident Commander + Engineering VP
  |             |-- NO  --> SEV2: Page on-call lead + notify engineering manager
  |-- NO  --> Is internal workflow or tooling degraded?
                |-- YES --> SEV3: Notify on-call engineer during business hours
                |-- NO  --> SEV4: Create ticket, address in next sprint
```

#### 5.3.2 Escalation Triggers

| Condition | Action |
|-----------|--------|
| No progress after 15 min (SEV1) | Escalate to next tier |
| No progress after 30 min (SEV2) | Escalate to next tier |
| Incident scope widens | Re-evaluate severity |
| Data breach suspected | Immediately escalate to Security + Legal |
| Customer communications needed | Notify Support / Comms lead |

#### 5.3.3 Escalation Contact Chain

| Tier | Role | Contact Method | Response SLA |
|------|------|---------------|-------------|
| Tier 1 | On-call engineer | PagerDuty / Slack | 5 min |
| Tier 2 | Team lead / senior engineer | Phone + Slack | 15 min |
| Tier 3 | Engineering manager / Incident Commander | Phone | 15 min |
| Tier 4 | VP Engineering / CTO | Phone | 30 min |

### 5.4 War Room Procedures

#### 5.4.1 War Room Activation Criteria

- All SEV1 incidents
- SEV2 incidents lasting > 30 minutes
- Any incident with cross-team dependencies
- Any incident with external customer communications

#### 5.4.2 War Room Setup

- **Primary channel**: {Slack channel / video bridge / physical room}
- **Bridge link**: {persistent video/voice link}
- **Status doc**: {shared document link for real-time notes}
- **Dashboard link**: {monitoring dashboard for the incident}

#### 5.4.3 War Room Roles

| Role | Responsibility | Filled By |
|------|---------------|-----------|
| Incident Commander (IC) | Owns decision-making, coordinates response, manages timeline | |
| Communications Lead | Sends stakeholder updates, manages external messaging | |
| Operations Lead | Executes diagnostic and mitigation actions | |
| Scribe | Maintains real-time timeline in the status doc | |
| Subject Matter Expert(s) | Provides domain expertise as needed | |

#### 5.4.4 War Room Protocols

- IC announces status and assigns roles within first 5 minutes
- Scribe logs every significant action with timestamp
- Status updates sent to stakeholders every {15 / 30} minutes
- All changes to production require IC approval
- Side conversations happen in threads, not main channel
- War room stays open until IC declares resolution

### 5.5 Mitigation & Resolution

## 6. Runbook Standards

### 6.1 Runbook Template
### 6.2 Required Runbooks

| Service | Failure Mode | Runbook | Owner | Last Tested |
|---------|-------------|---------|-------|-------------|

## 7. Postmortem Process

### 7.1 Trigger Criteria
### 7.2 Timeline & Ownership
### 7.3 Postmortem Template
### 7.4 Action Item Tracking

## 8. Post-Incident Review Scheduling

### 8.1 Review Trigger Criteria

| Condition | Review Required | Deadline |
|-----------|----------------|----------|
| SEV1 incident | Always | Within 3 business days |
| SEV2 incident | Always | Within 5 business days |
| SEV3 with customer impact | Recommended | Within 10 business days |
| SEV4 | Optional / at team discretion | Next sprint |
| Near-miss (almost SEV1/2) | Recommended | Within 5 business days |

### 8.2 Review Meeting Format

- **Duration**: 60 minutes (SEV1/2), 30 minutes (SEV3/4)
- **Attendees**: Incident responders, IC, affected team leads, optional: management observers
- **Facilitator**: Not the IC or primary responder (fresh perspective)
- **Agenda**:
  1. Timeline walkthrough (10 min)
  2. What went well (10 min)
  3. What could be improved (15 min)
  4. Action item generation and assignment (15 min)
  5. Wrap-up and follow-up scheduling (10 min)

### 8.3 Action Item Tracking

- **Tracking system**: {Jira / Linear / GitHub Issues / etc.}
- **Label / tag convention**: `postmortem`, `incident-{id}`
- **SLA for action item completion**: Critical (1 week), High (2 weeks), Medium (1 month)
- **Review cadence for open action items**: Weekly in team standup

### 8.4 Postmortem Distribution

- **Internal distribution list**:
- **Executive summary recipients**:
- **Published location**: {wiki / docs / shared drive}
- **Anonymization policy**: {for external sharing if applicable}

## 9. Training & Drills

- **Tabletop exercises**:
- **Game days**:
- **Onboarding**:
