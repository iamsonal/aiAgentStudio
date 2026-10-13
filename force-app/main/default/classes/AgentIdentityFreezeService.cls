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
 * Fail-closed identity and command-key immutability after insert. Lifecycle
 * status may still advance; snapshotted principal and operation identity may not.
 */
public inherited sharing class AgentIdentityFreezeService {
    public static void guardRuns(Map<Id, AgentRun__c> oldRuns, List<AgentRun__c> newRuns) {
        if (oldRuns == null || newRuns == null) {
            return;
        }
        for (AgentRun__c nextValue : newRuns) {
            AgentRun__c previous = oldRuns.get(nextValue.Id);
            if (previous == null) {
                continue;
            }
            if (changed(previous.InitiatingUser__c, nextValue.InitiatingUser__c)) {
                nextValue.addError('Initiating user is immutable after run start.');
            }
            if (changed(previous.AttendedBy__c, nextValue.AttendedBy__c)) {
                nextValue.addError('The person a run works for is immutable after run start.');
            }
            if (changed(previous.LoopbackNamedCredential__c, nextValue.LoopbackNamedCredential__c)) {
                nextValue.addError('Loopback Named Credential is immutable after run start.');
            }
            if (changed(previous.ExpectedPrincipalUser__c, nextValue.ExpectedPrincipalUser__c)) {
                nextValue.addError('Expected principal is immutable after run start.');
            }
            if (changed(previous.ExecutionIdentity__c, nextValue.ExecutionIdentity__c)) {
                nextValue.addError('Execution identity is immutable after run start.');
            }
            if (changed(previous.ParentRun__c, nextValue.ParentRun__c)) {
                nextValue.addError('Parent run is immutable after run start.');
            }
            if (changed(previous.ResolvedPrincipalUser__c, nextValue.ResolvedPrincipalUser__c)) {
                if (previous.ResolvedPrincipalUser__c != null) {
                    nextValue.addError('Resolved principal cannot be reassigned.');
                } else if (nextValue.ExpectedPrincipalUser__c != null && nextValue.ResolvedPrincipalUser__c != nextValue.ExpectedPrincipalUser__c) {
                    nextValue.addError('Resolved principal must match the snapshotted expected principal.');
                }
            }
            if (changed(previous.ExecutionContextStatus__c, nextValue.ExecutionContextStatus__c)) {
                if (
                    previous.ExecutionContextStatus__c != ExecutionIdentityService.CONTEXT_PENDING ||
                    nextValue.ExecutionContextStatus__c != ExecutionIdentityService.CONTEXT_ESTABLISHED
                ) {
                    nextValue.addError('Execution context can only move from Pending to Established.');
                }
            }
        }
    }

    public static void guardCommands(Map<Id, AgentCommand__c> oldCommands, List<AgentCommand__c> newCommands) {
        if (oldCommands == null || newCommands == null) {
            return;
        }
        for (AgentCommand__c nextValue : newCommands) {
            AgentCommand__c previous = oldCommands.get(nextValue.Id);
            if (previous == null) {
                continue;
            }
            if (changed(previous.OperationKey__c, nextValue.OperationKey__c)) {
                nextValue.addError('Operation key is immutable after command insert.');
            }
            if (changed(previous.DispatchToken__c, nextValue.DispatchToken__c)) {
                nextValue.addError('Dispatch token is immutable after command insert.');
            }
            if (changed(previous.CommandType__c, nextValue.CommandType__c)) {
                nextValue.addError('Command type is immutable after command insert.');
            }
            if (previous.AdmittedToolBindingHash__c != null && changed(previous.AdmittedEffects__c, nextValue.AdmittedEffects__c)) {
                nextValue.addError('Admitted effects are immutable after first lease.');
            }
            if (previous.AdmittedToolBindingHash__c != null && changed(previous.AdmittedToolBindingHash__c, nextValue.AdmittedToolBindingHash__c)) {
                nextValue.addError('Admitted tool binding is immutable after first lease.');
            }
            if (changed(previous.AgentRun__c, nextValue.AgentRun__c)) {
                nextValue.addError('Command run is immutable after command insert.');
            }
            if (previous.Sequence__c != null && previous.Sequence__c != nextValue.Sequence__c) {
                nextValue.addError('Command sequence is immutable after command insert.');
            }
            if (changed(previous.InputSource__c, nextValue.InputSource__c)) {
                nextValue.addError('Command input source is immutable after command insert.');
            }
            if (previous.BatchKey__c != null && changed(previous.BatchKey__c, nextValue.BatchKey__c)) {
                nextValue.addError('Batch key is immutable once assigned.');
            }
            if (previous.BatchOrdinal__c != null && changed(previous.BatchOrdinal__c, nextValue.BatchOrdinal__c)) {
                nextValue.addError('Batch ordinal is immutable once assigned.');
            }
        }
    }

    private static Boolean changed(Object previous, Object nextValue) {
        return previous != nextValue;
    }
}
