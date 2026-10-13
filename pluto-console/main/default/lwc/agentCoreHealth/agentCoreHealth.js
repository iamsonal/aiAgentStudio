/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getHealth from '@salesforce/apex/AgentRunOperatorController.getHealth';
import installSchedules from '@salesforce/apex/AgentRunOperatorController.installSchedules';
import runRecoveryNow from '@salesforce/apex/AgentRunOperatorController.runRecoveryNow';
import retryApprovalRelays from '@salesforce/apex/PlutoHitlController.retryApprovalRelays';

// One card per Health action. Core sends the reason and the numbers; this adds a title,
// how urgent it is, and the one-click fix. The Check health docs page has the full procedure.
const ACTIONS = {
    INSTALL_OR_REPAIR_SCHEDULES: { title: 'Schedules or recovery need attention', severity: 'error' },
    FIX_EXECUTION_IDENTITIES: {
        title: 'An execution identity needs fixing',
        severity: 'warning',
        button: { label: 'Open Identities', command: 'list', objectApiName: 'AgentExecutionIdentity__c', listView: 'All' }
    },
    RESCUE_OR_CANCEL_PAUSED_RUNS: {
        title: 'Runs are paused',
        severity: 'warning',
        button: { label: 'Open Paused Runs', command: 'list', objectApiName: 'AgentRun__c', listView: 'Paused_Runs' }
    },
    RECONCILE_UNKNOWN_CALLS: {
        title: 'Tool calls need checking',
        severity: 'error',
        button: { label: 'Open Runs', command: 'list', objectApiName: 'AgentRun__c', listView: 'Needs_Reconciliation' }
    },
    REVIEW_OPEN_ISSUES: {
        title: 'Failures need a person',
        severity: 'warning',
        button: { label: 'Open Issues', command: 'list', objectApiName: 'AgentOperationalIssue__c', listView: 'Open' }
    },
    REDUCE_LOAD: { title: 'Agent Core is near its limits', severity: 'info' }
};

// Plain labels for the numbers behind an action. Issue codes show as they are.
const COUNT_LABELS = {
    missingSchedules: 'missing schedules',
    failedSchedules: 'schedules with the wrong cadence or stuck',
    trustKeyMissing: 'trust key not created',
    staleLeasedCommands: 'steps overdue for recovery',
    dueOrphanCommands: 'steps never started',
    dueRetentionRuns: 'runs due for retention',
    failedExecutionIdentities: 'identities that failed Verify',
    unneededCredentialHolders: 'users with credential access they do not need',
    rescuablePausedRuns: 'you can rescue',
    starterOnlyPausedRuns: 'only their starter can continue',
    cancelOnlyPausedRuns: 'data removed, cancel only',
    initiatingUserRecoveryDeferred: 'waiting for their starter',
    unknownToolCalls: 'unconfirmed tool calls',
    issueSubscriberStopped: 'issue recording stopped',
    recoveryQuarantinedRuns: 'runs recovery set aside',
    lifecyclePublishFailures: 'lifecycle events not published',
    expiredApprovals: 'approvals expired',
    lifecycleEventCreateMissing: 'execution user cannot publish events',
    trustVaultFieldExposed: 'protected values readable',
    dailyLimitPressure: 'daily limits above 80%',
    recoveryCapacityDeferred: 'recovery items deferred',
    recoveryTargetMissed: 'recovery behind its 10-minute target',
    healthMetricsTruncated: 'report counts are partial',
    asyncJobBudgetExceeded: 'agent exceeds the job chain limit'
};

const VERDICTS = {
    Healthy: { tone: 'success', icon: 'utility:success', title: 'Healthy' },
    Warning: { tone: 'warning', icon: 'utility:warning', title: 'Needs attention' },
    Critical: { tone: 'error', icon: 'utility:error', title: 'Action required' }
};

export default class AgentCoreHealth extends NavigationMixin(LightningElement) {
    report;
    busy = false;
    errorMessage;
    checkedAt;

    connectedCallback() {
        this.load();
    }

    load = async () => {
        await this.run(async () => {
            this.report = await getHealth({ lookbackHours: 24 });
            this.checkedAt = new Date().toISOString();
        });
    };

    get loading() {
        return this.busy && !this.report;
    }

    get verdict() {
        return VERDICTS[this.report?.status] || VERDICTS.Critical;
    }

    get verdictClass() {
        return `verdict verdict_${this.verdict.tone}`;
    }

    get tiles() {
        const report = this.report || {};
        return [
            tile('paused', 'Paused runs', report.pausedRuns, 'warning', 'AgentRun__c', 'Paused_Runs'),
            tile('unknown', 'Unconfirmed tool calls', report.waitingUnknown, 'error', 'AgentRun__c', 'Needs_Reconciliation'),
            tile('pending', 'Pending approvals', report.pendingApprovals, 'info', 'AgentApproval__c', 'Pending'),
            tile('failed', 'Failed runs', report.recentFailed, 'error'),
            tile('expired', 'Expired approvals', report.expiredApprovals, 'warning'),
            tile('issues', 'Open issues', sumOf(report.openIssuesByCode), 'warning', 'AgentOperationalIssue__c', 'Open')
        ];
    }

    get findings() {
        return (this.report?.actions || []).map((action) => {
            const meta = ACTIONS[action.code] || { title: action.code, severity: 'warning' };
            const counts = action.counts || {};
            return {
                code: action.code,
                title: meta.title,
                action: action.reason,
                where: action.fixTarget,
                details: Object.keys(counts).map((key) => ({ key, text: `${counts[key]} ${COUNT_LABELS[key] || key}` })),
                className: `finding finding_${meta.severity}`,
                icon: meta.severity === 'error' ? 'utility:error' : meta.severity === 'info' ? 'utility:info' : 'utility:warning',
                button: action.code === 'INSTALL_OR_REPAIR_SCHEDULES' ? scheduleFix(counts) : meta.button,
                secondaryButton:
                    counts.AGENT_HITL_RELAY_FAILED || counts.AGENT_HITL_RELAY_REFUSED ? { label: 'Retry Relays', command: 'retryRelays' } : undefined
            };
        });
    }

    handleOpenList(event) {
        this.openList(event.currentTarget.dataset.object, event.currentTarget.dataset.list);
    }

    handleFindingAction(event) {
        const { command, object, list } = event.target.dataset;
        if (command === 'install') {
            this.handleInstall();
        } else if (command === 'recover') {
            this.handleRecover();
        } else if (command === 'list') {
            this.openList(object, list);
        } else if (command === 'retryRelays') {
            this.handleRetryRelays();
        }
    }

    openList(objectApiName, filterName) {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName, actionName: 'list' },
            state: { filterName }
        });
    }

    async handleInstall() {
        if (await this.run(() => installSchedules())) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Schedules installed', variant: 'success' }));
            await this.load();
        }
    }

    async handleRetryRelays() {
        let sent;
        if (
            await this.run(async () => {
                sent = await retryApprovalRelays();
            })
        ) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: `${sent} approval relays sent again`,
                    message: 'Their issues close when Agent Core records each decision.',
                    variant: 'success'
                })
            );
            await this.load();
        }
    }

    async handleRecover() {
        if (await this.run(() => runRecoveryNow())) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Recovery pass complete', variant: 'success' }));
            await this.load();
        }
    }

    async run(work) {
        this.busy = true;
        this.errorMessage = undefined;
        try {
            await work();
            return true;
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'Agent Core health is unavailable.';
            return false;
        } finally {
            this.busy = false;
        }
    }
}

function tile(key, label, count, tone, objectApiName, listView) {
    const value = count ?? 0;
    return {
        key,
        label,
        value,
        objectApiName,
        listView: value > 0 ? listView : undefined,
        linkTitle: `Open ${label.toLowerCase()}`,
        className: `tile${value > 0 ? ` tile_${tone}` : ''}`
    };
}

function sumOf(counts) {
    return Object.values(counts || {}).reduce((total, value) => total + (value || 0), 0);
}

/** Install when a schedule or the trust key is missing or broken; otherwise run recovery once. */
function scheduleFix(counts) {
    return counts.missingSchedules || counts.failedSchedules || counts.trustKeyMissing
        ? { label: 'Install Schedules', command: 'install' }
        : { label: 'Run Recovery', command: 'recover' };
}
