import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import resumeExecution from '@salesforce/apex/AgentExecutionResumeController.resumeExecution';

/**
 * Headless quick action component for resuming failed agent executions.
 * Supports AgentExecution__c records.
 *
 * According to Salesforce docs, headless quick actions:
 * - Execute custom code without opening a modal
 * - Don't automatically pass recordId in connectedCallback()
 * - Must expose invoke() as a public method
 * - invoke() executes every time the quick action is triggered
 */
export default class AgentExecutionResume extends NavigationMixin(LightningElement) {
    // Flag to prevent double execution
    isExecuting = false;

    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(recordId) {
        if (recordId !== this._recordId) {
            this._recordId = recordId;
        }
    }

    /**
     * Public method required for headless quick actions.
     * Executes every time the quick action is triggered.
     * @param {Object} event - The event object containing recordId
     */
    @api async invoke(event) {
        // Prevent double execution
        if (this.isExecuting) {
            console.warn('[AgentExecutionResume] Action already executing, ignoring duplicate call');
            return;
        }

        this.isExecuting = true;

        try {
            const recordId = this.recordId;

            if (!recordId) {
                this.showError('Execution ID is missing. This action must be run from an AgentExecution__c record page.');
                return;
            }

            console.log('[AgentExecutionResume] Resuming execution:', recordId);

            const result = await resumeExecution({ executionId: recordId });
            this.showSuccess('Execution Resumed', result);

            console.log('[AgentExecutionResume] Resume result:', result);

            // Refresh the current page to show updated status
            // Use a small delay to ensure the toast is visible
            setTimeout(() => {
                window.location.reload();
            }, 1500);
        } catch (error) {
            console.error('[AgentExecutionResume] Resume error:', error);
            const errorMessage = error.body?.message || error.message || 'Failed to resume execution';

            // Show validation errors as warnings instead of errors
            if (this.isValidationError(errorMessage)) {
                this.showWarning(errorMessage);
            } else {
                this.showError(errorMessage);
            }
        } finally {
            this.isExecuting = false;
        }
    }

    /**
     * Determines if an error message is a validation error vs system error
     */
    isValidationError(message) {
        if (!message) return false;

        const lowerMessage = message.toLowerCase();
        return (
            lowerMessage.includes('already completed') ||
            lowerMessage.includes('cannot be resumed') ||
            lowerMessage.includes('nothing to resume') ||
            lowerMessage.includes('no pending') ||
            lowerMessage.includes('status:')
        );
    }

    /**
     * Shows a success toast notification
     */
    showSuccess(title, message) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: 'success',
                mode: 'dismissable'
            })
        );
    }

    /**
     * Shows a warning toast notification for validation errors
     */
    showWarning(message) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Cannot Resume',
                message: message,
                variant: 'warning',
                mode: 'dismissable'
            })
        );
    }

    /**
     * Shows an error toast notification
     */
    showError(message) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Resume Failed',
                message: message,
                variant: 'error',
                mode: 'sticky'
            })
        );
    }
}
