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

@IsTest(SeeAllData=false)
private class SchemaFieldClassificationServiceTest {
    @IsTest
    static void cachesSalesforceMetadataPerObjectAndSupportsDeterministicTests() {
        SchemaFieldClassificationService.clearCache();
        Integer queriesBefore = Limits.getQueries();
        SchemaFieldClassificationService.isSensitive('Account', 'Name');
        Integer queriesAfterFirstLoad = Limits.getQueries();
        SchemaFieldClassificationService.isSensitive('Account', 'Description');

        System.assertEquals(queriesBefore + 1, queriesAfterFirstLoad);
        System.assertEquals(queriesAfterFirstLoad, Limits.getQueries(), 'Classification metadata must be loaded once per object and transaction.');

        SchemaFieldClassificationService.sensitiveFieldOverrides.put('account', new Set<String>{ 'description' });
        System.assertEquals(true, SchemaFieldClassificationService.isSensitive('Account', 'Description'));
        System.assertEquals(false, SchemaFieldClassificationService.isSensitive('Account', 'Name'));
    }
}
