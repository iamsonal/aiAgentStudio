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

/** The Pluto Health card retries failed approval relays through Agent HITL when it is installed. */
@IsTest
private class PlutoHitlControllerTest {
    private class FakeOperations implements System.Callable {
        private final Boolean allowed;

        FakeOperations(Boolean allowed) {
            this.allowed = allowed;
        }

        public Object call(String action, Map<String, Object> args) {
            if (!allowed) {
                throw new IllegalArgumentException('Retrying an approval relay needs Agent Kernel Operator, Agent Kernel Admin, or Agent HITL Admin.');
            }
            return action == 'retryRelays' ? 3 : null;
        }
    }

    @IsTest
    static void retriesEveryOpenRelayThroughThePackage() {
        PlutoHitlController.operationsForTest = new FakeOperations(true);
        Assert.areEqual(3, PlutoHitlController.retryApprovalRelays());
    }

    @IsTest
    static void personWithoutAccessGetsThePackagesRefusal() {
        PlutoHitlController.operationsForTest = new FakeOperations(false);
        try {
            PlutoHitlController.retryApprovalRelays();
            Assert.fail('The package refuses people without access.');
        } catch (AuraHandledException expected) {
            Assert.isTrue(expected.getMessage().contains('Agent HITL Admin'), expected.getMessage());
        }
    }
}
