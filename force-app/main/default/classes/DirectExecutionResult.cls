/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Result DTO for Direct runtime execution.
 */
public inherited sharing class DirectExecutionResult {
    public Boolean success;
    public String response;
    public Id executionId;
    public String status;
    public Boolean requiresPolling;
    public String executionUrl;
    public String errorCode;
    public String errorMessage;
    public Integer tokensUsed;
    public Long processingTimeMs;

    public DirectExecutionResult() {
        this.success = false;
        this.requiresPolling = false;
    }
}
