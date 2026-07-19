---
name: bgr-ops-review
description: 'Cross-agent operations review that lints all BGreat artifacts for consistency, coverage gaps, and staleness. Use when the user says "review operations artifacts" or "run ops review" or "check artifact consistency"'
---

# Operations Review

## Overview

This skill performs a cross-agent operations review across all BGreat artifacts in `{bgr_artifacts}/`. It reads every produced artifact, cross-references decisions and definitions across plans, detects coverage gaps and stale content, and produces a structured markdown report with pass/warn/fail verdicts per check.

This skill is read-only with respect to existing artifacts — it analyzes them without modification and writes a new report to `{bgr_artifacts}/ops-review-report.md`.

## Who Can Run This

Any agent (Morgan, Riley, or Sam) or the user directly. The skill is agent-agnostic because it reviews the combined output of all workflows.

## Instructions

### Step 1 — Discovery

Scan `{bgr_artifacts}/` for all existing artifacts. Identify which of the seven workflow outputs are present:

| Artifact | Expected Source Workflow |
|----------|------------------------|
| Observability plan | bgr-3-create-observability |
| Incident response plan | bgr-3-create-incident-response |
| Disaster recovery plan | bgr-3-create-disaster-recovery |
| Infrastructure plan | bgr-3-create-infrastructure |
| Capacity plan | bgr-3-create-capacity-plan |
| Pipeline plan | bgr-3-create-pipeline |
| Security plan | bgr-3-create-security-plan |

Also check for the production readiness checklist. Record which artifacts exist and which are missing.

### Step 2 — Consistency Checks

For every pair of artifacts that share cross-references, verify alignment. Check the following at minimum:

1. **SLO/SLI alignment** — SLO targets in the observability plan must match any SLO references in the incident response plan (severity thresholds), capacity plan (scaling triggers), and pipeline plan (deployment gates).
2. **Environment names** — Environment identifiers (e.g., dev, staging, production) must be consistent across the infrastructure plan, pipeline plan, disaster recovery plan, and capacity plan.
3. **Alerting-to-severity mapping** — Alert definitions in the observability plan must align with the severity classification in the incident response plan.
4. **Infrastructure references** — The pipeline plan deployment targets must reference environments defined in the infrastructure plan. The disaster recovery plan failover targets must match infrastructure topology.
5. **Technology choices** — Cloud provider, container orchestration platform, IaC tool, and CI/CD platform must be consistent across all artifacts that reference them.
6. **Threshold coherence** — Scaling thresholds in the capacity plan must not conflict with alerting thresholds in the observability plan or deployment gates in the pipeline plan.
7. **Security integration** — Security controls in the security plan should be referenced by the pipeline plan (scanning stages), infrastructure plan (network policies, secrets management), and incident response plan (security incident procedures).

For each check, record a verdict:

- **PASS** — Values are present and consistent across artifacts.
- **WARN** — Values are present but could not be verified as consistent (e.g., vague language, implicit references).
- **FAIL** — Values are present and contradictory, or a required cross-reference is missing.
- **SKIP** — One or both artifacts needed for this check do not exist.

### Step 3 — Coverage Gap Detection

Identify areas where no artifact addresses a production readiness concern. Check for:

1. **Missing artifacts** — Which of the seven workflow outputs have not been created?
2. **Incomplete sections** — Within existing artifacts, are there placeholder sections, TODO markers, or empty tables?
3. **Unaddressed cross-references** — Does the production readiness checklist reference decisions that no artifact defines?
4. **Orphaned references** — Does any artifact reference another artifact or decision that does not exist?

### Step 4 — Staleness Detection

For each artifact, check for signals that it may be outdated:

1. **Frontmatter dates** — Compare `lastUpdated` or similar date fields against each other. Flag artifacts whose dates diverge significantly from the most recently updated artifact.
2. **Version references** — If an artifact references specific tool versions, platform versions, or API versions, note them for manual review.
3. **Superseded decisions** — If a newer artifact makes a decision that contradicts an older artifact (e.g., changing cloud provider), flag the older artifact as potentially stale.

### Step 5 — Generate Report

Produce the report using the template at `./templates/ops-review-report.md`. Fill in every section with findings from the previous steps. Write the completed report to `{bgr_artifacts}/ops-review-report.md`.

After writing the report, present a summary to the user with:

- Total checks run and verdict counts (PASS / WARN / FAIL / SKIP)
- Top findings requiring attention
- Recommended next actions
