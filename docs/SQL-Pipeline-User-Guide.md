# How to run a SQL release in Azure DevOps

Use the **deployment pipeline** to apply SQL scripts and the separate **rollback pipeline** to undo selected features. Start with a dry run in `dev`. A deployment dry run shows which databases the checklist selects; it does **not** execute SQL, test database access, or run the SQL validation stage.

## 1. Before the first run

If the pipelines already exist, ask the pipeline owner for their names and confirm the checks below. Otherwise, in Azure DevOps go to **Pipelines > New pipeline**, choose the repository, select **Existing Azure Pipelines YAML file**, and save two separate definitions:

| Suggested pipeline name | Select this YAML | When it runs |
|---|---|---|
| SQL Deployment | [Pipelines/azure-pipelines.yml](../Pipelines/azure-pipelines.yml) | Manually with release parameters; the YAML also declares a `main` branch trigger. |
| SQL Feature Rollback | [Scripts/azure-pipelines-rollback.yml](../Scripts/azure-pipelines-rollback.yml) | Manually only. |

**Owner checks before enabling live runs:**

- Both definitions assume `Scripts`, `Environments`, and `workflow.sql` are directly under the agent working directory. In this workspace they are under `SQL`. If the checkout includes that extra directory, align the YAML paths and working directories before queuing a run.
- Replace `Your-Self-Hosted-Windows-Pool` with an authorized Windows agent pool. Confirm the agent can reach the intended SQL servers, and the operator has permission to queue runs and view artifacts.
- Authorize the Azure DevOps environment and the correct secret variable group for each target. Both supplied YAML files currently reference `mssql-vg-dev` and map only two example variables. Each configured `connectionStringVar` must match an environment variable mapped into the execution task. Never put the connection string itself in the CSV, JSON, logs, or screenshots.
- Configure the approval jobs before using either pipeline: `ManualValidation@1` requires an agentless job (`pool: server`) without a checkout step. The supplied YAML puts it in an agent job. Replace the example notification address and test that rejecting a dev run prevents execution. Do not bypass a failed or missing approval.
- Deployment labels production `PRD`; rollback uses `prod`. The supplied checklists cover dev and QA. Do not select production until deployment and rollback agree on the environment, files, credentials, and approvals.

## 2. Prepare the checklist and SQL files

1. On the release branch, place reviewed SQL files under `workflow.sql\<version>`. For a worked example, open the [dev checklist](../Environments/dev/dev.csv) and [dev client configuration](../Environments/dev/dev-config.json).
2. Edit `Environments\<env>\<env>.csv`. Preserve the header and use one row per deployment script. Alternatively, run [Generate-EnvironmentCSV.ps1](../Scripts/Generate-EnvironmentCSV.ps1) from the directory containing `workflow.sql` and `Environments`; review its changes and fill in the intended clients before enabling rows.
3. Check the fields below for every row you intend to deploy:

   | Checklist field | What to enter or verify |
   |---|---|
   | `Release_Version`, `Environment` | Exact release and environment you will select in the run form, e.g. `1.0.0` and `dev`. |
   | `Application_Name`, `Feature_Name` | Names used by the filters, e.g. `Workflow` and `Teacher`. |
   | `Execute_Script` | `Yes` to select the row for deployment; `No` to leave it out. |
   | `Feature_Order`, `Script_order` | Numeric execution order. Put dependencies before their dependents. |
   | `Client_Name` | A `clientName` in the environment JSON. For multiple names, quote the CSV cell, e.g. `"WorkflowPrimaryServer,WorkflowSecondaryServer"`. A name can expand to several databases; a blank name is skipped, not treated as “all clients.” |
   | `SQL_Path` | Required file relative to the working directory, e.g. `workflow.sql\1.0.0\002_teacher\01_common.sql`. |
   | `Prerequisites` | Leave blank if none; otherwise enter the dependent script's prerequisite file path. Include that earlier script in the selected plan and verify it targets the same database. |
   | `Rollback_Script_Path`, `Feature_Rollback_Order` | If a rollback script exists, enter its file path and verify its undo order. A blank path passes deployment parsing but provides no rollback script for that row. |

4. Check the JSON entries for each selected name: verify the server, database list, client ID, and connection variable name. Have the CSV, JSON, deployment scripts, and any rollback scripts reviewed together. Record the reviewed commit so the preview and live run use the same inputs.

**Screenshot 1 (add manually):** A sample checklist showing release, feature, order, and a prerequisite. Use fictitious client names.

## 3. Preview a deployment

1. Open **Pipelines > SQL Deployment > Run pipeline** (use your project's actual pipeline name). Select the branch or tag containing the reviewed commit.
2. For a first run with the supplied dev checklist, enter these values:

   | Run form field | Example | What it controls |
   |---|---|---|
   | Release_Version | `1.0.0` | Selects rows for this release. |
   | Environment | `dev` | Chooses the checklist, config, and deployment environment. |
   | Application Filter | `Workflow` | One application, or `all`. |
   | Feature Filter | `Teacher` | One feature, a comma-separated list, or `all`. |
   | Rollback Strategy | `Progressive` | Keeps completed scripts on failure. `AtomicFeature` attempts to undo completed work for the affected feature; `CascadingApplication` extends rollback to the application. Review rollback coverage before choosing either. |
   | Client Resilience Mode | `StopOnFirstClientFailure` | Stops processing the current feature on first failure. `ContinueOnClientFailure` allows other targets to continue and isolates the failed target; it does not make the failure a success. |
   | Excluded Clients | Leave empty | Deployment accepts comma-separated config names or client IDs. Excluding a name removes that entry; excluding an ID can also remove its databases reached through group entries. |
   | Dry Run | **Checked** | Preview only. Leave checked for the first run. |

3. Select **Run**, then open **Parse Feature-Based Release Checklist** in the job logs. Check the total rows, sample plan (up to ten rows), expansion messages, and skipped rows. With the unmodified dev example, `Teacher` selects `01_common.sql` followed by `02_allteachers.sql` for `Client001`. If the targets differ from your intention, stop here.
4. Use the **log**, not an artifact, for the dry-run preview: the parser exits before writing `execution_plan.csv`. The full plan is written during a non-dry run, before approval.

**Screenshot 2 (add manually):** The run form with `dev`, `Teacher`, and **Dry Run** selected.  
**Screenshot 3 (add manually):** The preview log showing script order and target count.

## 4. Run, review, and approve the deployment

1. Queue a **new run** with the same commit, environment, filters, exclusions, and failure settings. Clear **Dry Run** only when ready for a live deployment. If inputs changed, preview again.
2. After **ParseChecklist**, open the run summary's published artifacts. Download **ExecutionPlan** and inspect `execution_plan.csv`. Check **every** script, server, database, client, and order, not just the preview sample. Review `skipped_rows.csv` if present.
3. Open **Validate SQL Scripts** and confirm it actually ran and succeeded. A skipped validation step is not a pass. If scope, validation, or rollback coverage is wrong, reject the run and correct the release inputs.
4. At **Manual Approval**, the authorized reviewer selects **Resume** to deploy or **Reject** to stop. If there is no expected approval prompt, stop and contact the pipeline owner.
5. Follow **Deploy SQL Scripts by Feature**. When it finishes, open **ExecutionResults** in the run summary. Review `executionsql-results-<buildId>.csv` by target and script; use `deployment-report-<buildId>.html` and `deployment-analysis.json` when available. Save the run link with the release record.

**If deployment fails:** Do not rerun the whole release immediately. Some scripts may have committed, some may have been undone, and others may have been skipped. Reconcile the result rows with the actual database state and agree the recovery scope with the database owner.

**Screenshot 4 (add manually):** Approval screen with the plan review instructions.  
**Screenshot 5 (add manually):** Run artifacts showing **ExecutionPlan** and **ExecutionResults**.

## 5. Roll back selected features

1. Identify the original deployment run, commit, and exact targets that still need undoing. The rollback pipeline builds a plan from the **checklist**, not from that run's success history. Do not assume it will automatically omit scripts that never ran or were already rolled back.
2. Open **SQL Feature Rollback > Run pipeline**. Select the matching revision, release, environment, and application. Enter the required comma-separated **Features to Roll Back** and keep **Dry Run** checked. Use explicit checklist client names for rollback exclusions; do not assume deployment's client-ID expansion applies.
3. Open **RollbackPlan > rollback_plan.csv**. Compare every target, script, and undo order with the deployment results. Confirm each rollback file exists at the selected revision. If a row has no rollback path it is not part of this plan. If the plan includes any unintended work or omits required work, **do not approve**.
4. Queue a new rollback run with the same reviewed inputs and **Dry Run** cleared. Review its fresh preview, then select **Resume** at **Approve Rollback Execution** only if it matches.
5. Download **RollbackResults** and inspect `rollback-results-<buildId>.csv`. Verify the database state with the database owner and record the rollback run link.

**Screenshot 6 (add manually):** The rollback plan showing feature, script order, and target using non-sensitive example data.

## Troubleshooting

| What you see | What to do |
|---|---|
| Parser reports a CSV row and `Client_Name` | Open that row (header = row 1). Match each comma-separated name to `clientName` in the selected environment's JSON. A deployment exclusion does not make an unknown name valid. |
| Parser reports `SQL_Path`, `Prerequisites`, or `Rollback_Script_Path` | Verify the exact value resolves to a **file**, not a directory, in the checked-out revision and working directory. Only the last two fields may be blank. |
| File exists but prerequisite validation fails | Check that the prerequisite's deployment row survived release, environment, execute, and feature filters. File existence and inclusion in the plan are separate checks. |
| No scripts found or no execution plan rows | Verify the release, environment, `Execute_Script=Yes`, filters, client names, and exclusions. Do not broaden to `all` unless all those targets are intended. |
| Approval job is rejected by Azure DevOps or connection variable is missing | Contact the pipeline owner to correct the agentless approval job or environment-specific secret mapping. Do not paste a secret into the checklist or skip approval. |

To insert a screenshot later, save a redacted image under `docs\images` and replace the corresponding screenshot note with a Markdown image, for example `![Dev deployment run form with Dry Run selected](images/deployment-dry-run.png)`. Keep the written steps so the guide remains usable without images.
