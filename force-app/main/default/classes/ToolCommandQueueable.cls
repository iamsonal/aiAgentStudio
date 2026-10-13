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

/**
 * Runs one leased tool command in its own job. ToolCommandExecutor does the
 * work, so a call that runs in the model worker's transaction is checked and
 * recorded the same way. After a Reads Outside Systems call, the job also runs
 * the Stays in This Org calls that follow it, so they add no job. A limit error
 * there loses the read's outcome, which is safe because the read may repeat;
 * the retry then runs each call in its own job. A Changes Outside Systems
 * outcome must commit on its own, so no call follows it here.
 */
public without sharing class ToolCommandQueueable implements Queueable, Database.AllowsCallouts {
    private final Id runId;
    private final Id commandId;
    private final Decimal expectedRevision;
    private final String operationKey;
    private final String leaseToken;

    public ToolCommandQueueable(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String leaseToken) {
        this.runId = runId;
        this.commandId = commandId;
        this.expectedRevision = expectedRevision;
        this.operationKey = operationKey;
        this.leaseToken = leaseToken;
    }

    public void execute(QueueableContext context) {
        Id workerJobId = context == null ? null : context.getJobId();
        ToolCommandExecutor executor = new ToolCommandExecutor(runId, commandId, expectedRevision, operationKey, leaseToken);
        executor.run(workerJobId, null);
        if (mayRunNextCallsInPlace(executor.ownedCommand)) {
            InPlaceToolRunner.runNext(
                runId,
                InPlaceToolRunner.byName(AgentRunConfigurationService.getTools(runId)),
                workerJobId,
                executor.continuationFinalizer
            );
        }
    }

    private static Boolean mayRunNextCallsInPlace(AgentCommand__c command) {
        return command != null &&
            AgentToolTypeService.isRetrySafe(command) &&
            AgentToolTypeService.admittedEffects(command) == AgentToolTypeService.EFFECTS_READS_OUTSIDE &&
            (command.DeliveryAnomalyCount__c == null ||
            command.DeliveryAnomalyCount__c == 0);
    }
}
