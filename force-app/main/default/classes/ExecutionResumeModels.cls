/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Shared DTOs for execution resume planning across strategy runtimes.
 */
public inherited sharing class ExecutionResumeModels {
    public enum ResumeType {
        RETRY_FAILED_TOOL,
        LLM_CONTINUE,
        RETRY_STEP,
        FRESH_START
    }

    public class ResumePoint {
        public ResumeType resumeType;
        public Integer turnCount;
        public Integer lastTurnCount;
        public String toolCallId;
        public String toolName;
        public String stepName;
        public String previousStatus;
        public Map<String, Object> metadata;

        public ResumePoint() {
            this.metadata = new Map<String, Object>();
        }
    }

    public class ResumeOptions {
        @AuraEnabled
        public Boolean retryFailedTool { get; set; }
        @AuraEnabled
        public String resumeReason { get; set; }
        @AuraEnabled
        public String stepName { get; set; }

        public ResumeOptions() {
            this.retryFailedTool = null;
        }

        public ResumeOptions(Boolean retryFailedTool) {
            this.retryFailedTool = retryFailedTool;
        }

        public ResumeOptions withRetryFailedTool(Boolean retry) {
            this.retryFailedTool = retry;
            return this;
        }

        public ResumeOptions withReason(String reason) {
            this.resumeReason = reason;
            return this;
        }

        public ResumeOptions withStepName(String step) {
            this.stepName = step;
            return this;
        }
    }
}
