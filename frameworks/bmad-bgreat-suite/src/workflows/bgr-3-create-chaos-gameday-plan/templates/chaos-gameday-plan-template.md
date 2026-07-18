---
status: draft
stepsCompleted: []
inputDocuments: []
crossWorkflowContext: []
createdDate: ""
lastUpdated: ""
---

# Chaos Engineering Game Day Plan

## 1. Overview

- **Project**:
- **Author**:
- **Game Day Lead**:
- **Planned Date**:
- **Environment**:

## 2. Game Day Scope and Goals

- **Goal**:
- **Environment**:
- **Session window**:
- **Team experience level**:

## 3. Steady-State Metrics

| Metric | Normal Range | Threshold | Source |
|--------|-------------|-----------|--------|

## 4. Experiments

<!-- Experiments are added here during step 2 -->

## 5. Experiment Sequence

| Order | Experiment | Target | Risk Level | Rationale |
|-------|-----------|--------|-----------|-----------|

## 6. Blast Radius Controls

<!-- Blast radius, abort conditions, and rollback procedures are added here during step 3 -->

## 7. Pre-Game-Day Checklist

### System Health

- [ ] All steady-state metrics within normal range
- [ ] No active incidents in target environment
- [ ] No recent deployments in past defined window
- [ ] All observability dashboards confirmed functional
- [ ] On-call rotation staffed and aware of game day

### Team Readiness

- [ ] All participants confirmed in game day channel
- [ ] Roles assigned: Game Day Lead, Safety Officer, Tool Operator(s), Scribe
- [ ] Rollback procedures reviewed by all tool operators
- [ ] Communication channel open and tested

## 8. Safety Gates

| Gate | Trigger | Action |
|------|---------|--------|
| Pre-game | Any pre-check fails | Reschedule game day |
| Between experiments | Steady state not restored | Hold until restored |
| Mid-experiment abort | Abort condition triggered | Execute rollback immediately |
| Post-experiment | Rollback SLA breached | Escalate to on-call; cancel remaining experiments |
| End of day | Any open issues | Do not close until all systems restored |

## 9. Game Day Roles

| Role | Responsibility | Assigned To |
|------|---------------|-------------|
| Game Day Lead | Owns the game day agenda, pacing, and go/no-go decisions | |
| Safety Officer | Monitors steady-state metrics; calls abort if conditions met | |
| Tool Operator(s) | Executes fault injection and rollback commands | |
| Scribe | Records observations, timeline, and findings in real time | |
| Observer(s) | Watches service behavior and secondary metrics | |

## 10. Game Day Execution Schedule

<!-- Execution schedule and per-experiment observation points are added here during step 4 -->

## 11. Findings Classification

| Finding Type | Definition | Action Required |
|-------------|------------|----------------|
| Hypothesis Confirmed | System behaved as expected | Document as resilience evidence |
| Hypothesis Refuted | System did not behave as expected | Classify severity; create action item |
| Unexpected Behavior | Out-of-scope behavior observed | Investigate; classify severity |
| Near Miss | System recovered via unintended path | Classify as High or Critical |

### Severity Scale

| Severity | Criteria | Response SLA |
|----------|----------|-------------|
| Critical | Availability loss, data risk, or blast radius exceeded | Fix before next game day |
| High | Hypothesis refuted; degradation observed | Address within next sprint |
| Medium | Unexpected behavior; no user impact | Add to backlog |
| Low | Hypothesis confirmed; positive signal | Document as evidence |

## 12. Post-Game Analysis Template

### Executive Summary

<!-- Complete after game day -->

### Experiment Results

| Experiment | Hypothesis | Actual Behavior | Verdict | Severity |
|-----------|-----------|----------------|---------|----------|

### Key Findings

<!-- Complete after game day -->

### Findings-to-Action Tracker

| Finding | Severity | Owner | Target Date | Status | Issue Link |
|---------|----------|-------|-------------|--------|-----------|

### What Worked Well

<!-- Complete after game day -->

### Process Improvements

<!-- Complete after game day -->

### Recommended Next Game Day Candidates

<!-- Complete after game day -->
