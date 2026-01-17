/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Flow-invocable wrapper for processing AsyncFrameworkRequest__e platform events. Delegates to AsyncFrameworkRequestTriggerHandler.
 */
public with sharing class AsyncFrameworkRequestFlowInvoker {
    @InvocableMethod(Label='Process Async Framework Request PE' Description='Called by Flow to process AsyncFrameworkRequest__e events')
    public static void processEvents(List<AsyncFrameworkRequest__e> platformEvents) {
        System.debug(
            LoggingLevel.INFO,
            '[AsyncFrameworkRequestFlowInvoker] Invoked by Flow to process ' + platformEvents.size() + ' AsyncFrameworkRequest__e event(s).'
        );
        AsyncFrameworkRequestTriggerHandler.handleEvents(platformEvents);
    }
}
