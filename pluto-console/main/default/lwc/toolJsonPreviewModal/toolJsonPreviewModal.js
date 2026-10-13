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

import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/** The exact input schema the model receives for a tool, read-only. */
export default class ToolJsonPreviewModal extends LightningModal {
    @api inputSchema = '';
    /** Shown instead of the JSON when there is none yet. */
    @api emptyMessage = '';

    get hasSchema() {
        return !!this.inputSchema;
    }

    handleClose() {
        this.close();
    }
}
