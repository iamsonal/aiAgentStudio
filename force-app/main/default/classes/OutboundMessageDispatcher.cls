/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Strategy-safe dispatcher that applies channel delivery after
 * terminality has been determined.
 */
public inherited sharing class OutboundMessageDispatcher {
    public ChannelDeliveryPolicyService.DeliveryResult dispatchContent(OrchestrationContext context, String contentResponse, String logPrefix) {
        return new ChannelDeliveryPolicyService().applyContentDelivery(context, contentResponse, logPrefix);
    }
}
