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

/** The Pluto Overview shows Agent Channels health when the package is there, and says so when it is not. */
@IsTest
private class PlutoChannelsControllerTest {
    private class FakeOperations implements System.Callable {
        private final Boolean allowed;
        private List<String> calls = new List<String>();

        FakeOperations(Boolean allowed) {
            this.allowed = allowed;
        }

        public Object call(String action, Map<String, Object> args) {
            calls.add(action);
            if (!allowed) {
                throw new IllegalArgumentException('The Agent Channels Operate permission is required.');
            }
            if (action == 'snapshot') {
                return new Map<String, Object>{ 'parked' => 2, 'sweepInstalled' => false };
            }
            if (action == 'parked') {
                return new List<Object>();
            }
            if (action == 'installSweep') {
                return UserInfo.getUserId();
            }
            return args.get('messageId') != null;
        }
    }

    @IsTest
    static void showsChannelHealthAndRunsFixesThroughThePackage() {
        FakeOperations fake = new FakeOperations(true);
        PlutoChannelsController.operationsForTest = fake;

        Map<String, Object> health = PlutoChannelsController.getChannelsHealth();
        Id job = PlutoChannelsController.installChannelsSweep();
        Boolean accepted = PlutoChannelsController.retryChannelMessage(UserInfo.getUserId());

        Assert.areEqual(true, health.get('available'));
        Assert.areEqual(2, ((Map<String, Object>) health.get('snapshot')).get('parked'));
        Assert.isNotNull(job);
        Assert.isTrue(accepted);
        Assert.areEqual(new List<String>{ 'snapshot', 'parked', 'installSweep', 'retry' }, fake.calls);
    }

    @IsTest
    static void personWithoutOperateGetsThePackagesRefusal() {
        PlutoChannelsController.operationsForTest = new FakeOperations(false);
        try {
            PlutoChannelsController.installChannelsSweep();
            Assert.fail('The package refuses people without Agent Channels Operate.');
        } catch (AuraHandledException expected) {
            Assert.isTrue(expected.getMessage().contains('Operate'), expected.getMessage());
        }
    }
}
