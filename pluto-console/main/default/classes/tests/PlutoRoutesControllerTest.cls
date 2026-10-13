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

@IsTest
private class PlutoRoutesControllerTest {
    @IsTest
    static void listsBoundedNotificationServiceChoicesWithoutAnOptionalPackageDependency() {
        List<PlutoRoutesController.ServiceOption> options = PlutoRoutesController.getNotificationServiceOptions();
        Assert.isNotNull(options, 'A missing optional catalog returns an empty list.');
        Assert.isTrue(options.size() <= 500, 'Setup discovery is bounded.');
        Set<String> names = new Set<String>();
        for (PlutoRoutesController.ServiceOption option : options) {
            Assert.isFalse(String.isBlank(option.value), 'The stored choice is a metadata API name.');
            Assert.isTrue(option.label.contains(option.value), 'The label identifies the stored choice.');
            Assert.isFalse(names.contains(option.value), 'Each service is listed once.');
            names.add(option.value);
        }
    }
}
