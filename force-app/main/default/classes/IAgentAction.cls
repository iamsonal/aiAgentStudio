/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Contract for all executable AI agent actions in the framework.
 * Enforces consistent execution signature and error handling.
 *
 * Action metadata (labels, descriptions, schemas) is defined via doc comment
 * annotations in the Apex class and generated into StandardActionHandler__mdt
 * by the build script. See scripts/generate-action-metadata.js for details.
 */
public interface IAgentAction {
    /**
     * Executes agent action with configuration and arguments.
     *
     * @param actionConfigurationJson Action configuration JSON
     * @param argumentsJson          Action arguments JSON
     * @param context                Action context
     * @return                       Action outcome
     */
    ActionOutcome execute(String actionConfigurationJson, String argumentsJson, ActionContext context);
}
