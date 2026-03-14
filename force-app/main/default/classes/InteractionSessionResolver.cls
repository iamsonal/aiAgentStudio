/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Channel-agnostic resolver for durable interaction sessions.
 */
public inherited sharing class InteractionSessionResolver {
    public InteractionRuntimeModels.InteractionSessionContext resolve(
        InteractionRuntimeModels.IInteractionChannel channel,
        AIAgentDefinition__c agentDefinition,
        InteractionRuntimeModels.InteractionEnvelope envelope,
        String logPrefix
    ) {
        return channel.resolveOrCreateSession(agentDefinition, envelope, logPrefix);
    }
}
