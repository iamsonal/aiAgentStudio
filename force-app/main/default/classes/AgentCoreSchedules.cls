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
 * The one setup step for Agent Core's scheduled work: the org trust key, the
 * ten-minute lease recovery jobs, and the daily payload retention job. Run it
 * as the intended schedule owner, who holds AgentKernelAdmin. Safe to repeat;
 * it replaces jobs with the wrong cadence or a stuck state.
 */
global with sharing class AgentCoreSchedules {
    global class InstallResult {
        @AuraEnabled
        global Id recoveryJobId;
        @AuraEnabled
        global Id retentionJobId;
    }

    global static InstallResult install() {
        InstallResult result = new InstallResult();
        result.recoveryJobId = CommandLeaseRecoveryScheduler.install();
        result.retentionJobId = PayloadRetentionPurgeScheduler.install();
        return result;
    }

    global static Integer remove() {
        return CommandLeaseRecoveryScheduler.remove() + PayloadRetentionPurgeScheduler.remove();
    }
}
