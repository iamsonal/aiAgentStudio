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

import { LightningElement, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';

const NAV_ITEMS = [
    {
        label: 'Overview',
        name: 'overview',
        iconName: 'standard:home',
        description: 'Review what is configured and jump to the main setup areas.'
    },
    {
        label: 'Settings',
        name: 'settings',
        iconName: 'standard:settings',
        description: 'Review org-wide defaults for retries, trust, and retention.'
    }
];

// The URL holds the selected section: ?c__section=overview|settings.
// Setup records live on their own object tabs and record pages, not here.
const TAB_API_NAME = 'PlutoHome';

export default class PlutoSetupContainer extends NavigationMixin(LightningElement) {
    selectedNavItemName = 'overview';

    @wire(CurrentPageReference)
    setPageReference(pageRef) {
        const requestedSection = pageRef?.state?.c__section;
        this.selectedNavItemName = NAV_ITEMS.some((item) => item.name === requestedSection) ? requestedSection : 'overview';
    }

    get navItems() {
        return NAV_ITEMS;
    }

    get selectedNavItem() {
        return NAV_ITEMS.find((item) => item.name === this.selectedNavItemName);
    }

    get isOverview() {
        return this.selectedNavItemName === 'overview';
    }

    get isPlaceholderSection() {
        return !this.isOverview;
    }

    // Replace the URL so Back does not stop on every section switch.
    handleNavItem(event) {
        const nextSectionName = event.detail.name;
        if (!nextSectionName || nextSectionName === this.selectedNavItemName) {
            return;
        }
        this[NavigationMixin.Navigate](
            {
                type: 'standard__navItemPage',
                attributes: { apiName: TAB_API_NAME },
                state: { c__section: nextSectionName }
            },
            true
        );
    }
}
