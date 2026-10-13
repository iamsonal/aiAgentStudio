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
import { recordPage } from 'c/plutoLink';

/** One model or tool attempt: what Core sent, what came back, and the provider's own evidence. */
export default class PlutoRunStoryCall extends LightningElement {
    /** A view from plutoRunStoryModel.describeCall. */
    @api call;
    /** Open the prompt and reply sections; later attempts of a retried step start closed. */
    @api expanded = false;
    /** The agent's tool Ids by the name the model saw; a tool without one is shown without a link. */
    @api toolIds;

    get prompt() {
        return this.call.prompt;
    }

    get reply() {
        return this.call.reply;
    }

    get toolRun() {
        return this.call.toolRun;
    }

    showRaw = false;

    get rawLabel() {
        return this.showRaw ? 'Readable view' : 'Raw evidence';
    }

    get rawTitle() {
        return this.showRaw ? 'Show this call in plain words' : 'Show the request and response exactly as Core stored them for audit';
    }

    handleRawToggle() {
        this.showRaw = !this.showRaw;
    }

    get showModel() {
        return this.call.isModel && this.call.hasEvidence;
    }

    get showTool() {
        return !this.call.isModel && this.call.hasEvidence;
    }

    get tools() {
        const ids = this.toolIds || {};
        return this.prompt.tools.map((tool) => ({
            ...tool,
            pageReference: ids[tool.name] ? recordPage(ids[tool.name], 'AgentTool__c') : null,
            openLabel: `Open tool ${tool.name}`
        }));
    }

    get budgetClass() {
        return `budget-fill budget-fill_${this.prompt.budgetTone}`;
    }

    get budgetStyle() {
        return `width: ${Math.max(this.prompt.budgetPercent, 2)}%`;
    }

    get hasResources() {
        return this.call.resources.length > 0;
    }

    get replyFacts() {
        return this.reply.facts.map((fact) => ({ ...fact, valueClass: fact.mono ? 'fact-value fact-value_mono' : 'fact-value' }));
    }
}
