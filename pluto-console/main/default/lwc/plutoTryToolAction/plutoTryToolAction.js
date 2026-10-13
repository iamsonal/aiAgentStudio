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

import { LightningElement, api } from 'lwc';
import ToolTryModal from 'c/toolTryModal';

/** Try Tool in the tool record page's highlights panel. */
export default class PlutoTryToolAction extends LightningElement {
    @api recordId;

    @api
    invoke() {
        return ToolTryModal.open({ size: 'medium', label: 'Try tool', toolId: this.recordId });
    }
}
