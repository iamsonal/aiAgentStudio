/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Reads and returns the text content of a file attached to a Salesforce record.
 *              Files are always resolved through ContentDocumentLink.LinkedEntityId.
 *
 * @ActionLabel Analyze File
 * @ActionDescription Reads the text content of a file attached to a Salesforce record or email
 * @ActionRequiresSObject false
 * @ActionIsActive true
 * @ActionHasVariants true
 * @ActionVariant from_record | From Record | Read a file attached to the current record. Call with no arguments to auto-read the only file, or supply contentDocumentId to target a specific one.
 * @ActionVariant by_file_id | By File ID | Read a specific file using its Salesforce ContentDocument ID. Use when the file ID is already known (e.g. surfaced in the email attachment list).
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionAnalyzeFile extends BaseAgentAction {
    @TestVisible
    private static final String VARIANT_FROM_RECORD = 'from_record';
    @TestVisible
    private static final String VARIANT_BY_FILE_ID = 'by_file_id';
    private static final Integer DEFAULT_MAX_FILE_SIZE_KB = 50;
    @TestVisible
    private static final Integer CDL_QUERY_LIMIT = 25;

    private ConfigDTO config;

    // ─── DTOs ────────────────────────────────────────────────────────────────────

    /**
     * Admin-configured backend configuration.
     */
    public class ConfigDTO {
        /**
         * @FieldSystem true
         * @FieldLabel Variant
         * @FieldType string
         * @FieldHelp Lookup mode: "from_record" (resolve via ContentDocumentLink) or "by_file_id" (direct ContentDocument ID). Managed by the variant picker UI.
         */
        public String variant;

        /**
         * @FieldLabel Max File Size (KB)
         * @FieldType integer
         * @FieldRequired false
         * @FieldPlaceholder 50
         * @FieldHelp Maximum file size in kilobytes that this tool will attempt to decode. Files exceeding this limit return a structured failure. Default: 50 KB.
         */
        public Integer maxFileSizeKb;

        /**
         * @FieldLabel Allowed File Extensions
         * @FieldType array
         * @FieldRequired false
         * @FieldPlaceholder ["csv","txt","json"]
         * @FieldHelp Optional restriction list. If set, only files whose extension matches an entry are processed; all others receive an unsupported-format failure. If omitted, all extensions are attempted.
         */
        public List<String> allowedFileExtensions;
    }

    /**
     * LLM-facing parameters for the from_record variant.
     */
    public class FromRecordArgumentsDTO {
        /**
         * @FieldLabel Linked Entity ID
         * @FieldType salesforce-id
         * @FieldRequired false
         * @FieldPlaceholder 001000000000000AAA
         * @FieldHelp Salesforce ID of the record the file is attached to (via ContentDocumentLink). Omit to use the record that triggered this agent.
         */
        public String linkedEntityId;

        /**
         * @FieldLabel Content Document ID
         * @FieldType salesforce-id
         * @FieldRequired false
         * @FieldPlaceholder 069000000000000AAA
         * @FieldHelp Salesforce ContentDocument ID of the specific file to read. If multiple files are attached and you know which one to read, provide this directly.
         */
        public String contentDocumentId;
    }

    /**
     * LLM-facing parameters for the by_file_id variant.
     */
    public class ByFileIdArgumentsDTO {
        /**
         * @FieldLabel Content Document ID
         * @FieldType salesforce-id
         * @FieldRequired true
         * @FieldPlaceholder 069000000000000AAA
         * @FieldHelp Salesforce ContentDocument ID of the file to read. Use the file ID shown in the email attachment list.
         */
        public String contentDocumentId;
    }

    /** Lightweight file reference returned in the disambiguation response. */
    public class FileRef {
        public String contentDocumentId;
        public String title;
        public String fileType;
        public Long sizeBytes;
    }

    /** Returned when exactly one file was found and decoded successfully. */
    public class AnalyzeFileResult {
        public String filename;
        public String fileType;
        public Long sizeBytes;
        public String linkedEntityId;
        public String content;
        /**
         * Present only for binary files (images, PDFs) on vision-capable LLMs.
         * Structure: { "mimeType": "image/png", "base64": "<base64-encoded data>" }
         * Detected by LLMFormattingService during history replay to build content-array format.
         */
        public Map<String, Object> multimodal;
    }

    /** Returned when multiple files are attached and the LLM must pick one. */
    public class DisambiguationResult {
        public String action = 'disambiguation_required';
        public String message;
        public List<FileRef> files;
    }

    // ─── Configuration parsing ────────────────────────────────────────────────────

    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        this.config = new ConfigDTO();
        this.config.maxFileSizeKb = DEFAULT_MAX_FILE_SIZE_KB;
        this.config.variant = VARIANT_FROM_RECORD;

        if (String.isNotBlank(actionConfigurationJson)) {
            try {
                Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

                String v = ActionConfigUtils.getOptionalString(configMap, 'variant');
                if (String.isNotBlank(v)) {
                    this.config.variant = v;
                }

                Integer maxKb = ActionConfigUtils.getOptionalInteger(configMap, 'maxFileSizeKb', DEFAULT_MAX_FILE_SIZE_KB);
                this.config.maxFileSizeKb = (maxKb != null && maxKb > 0) ? maxKb : DEFAULT_MAX_FILE_SIZE_KB;

                this.config.allowedFileExtensions = ActionConfigUtils.getOptionalStringList(configMap, 'allowedFileExtensions');

                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix +
                        'Config parsed. variant=' +
                        this.config.variant +
                        ' maxFileSizeKb=' +
                        this.config.maxFileSizeKb +
                        ' allowedFileExtensions=' +
                        this.config.allowedFileExtensions
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Failed to parse configuration: ' + e.getMessage() + '. Using defaults.');
            }
        }
    }

    // ─── Main dispatch ────────────────────────────────────────────────────────────

    public override ActionOutcome executeAction(Map<String, Object> params) {
        String logPrefix = '[ActionAnalyzeFile variant=' + config.variant + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting execution.');

        if (VARIANT_BY_FILE_ID.equals(config.variant)) {
            return executeByFileId(params, logPrefix);
        }
        return executeFromRecord(params, logPrefix);
    }

    // ─── from_record path ────────────────────────────────────────────────────────

    private ActionOutcome executeFromRecord(Map<String, Object> params, String logPrefix) {
        // If the LLM already has a contentDocumentId, skip entity lookup entirely
        String directDocId = extractOptionalId(params, 'contentDocumentId', logPrefix);
        if (String.isNotBlank(directDocId)) {
            return readAndReturnFile(directDocId, null, logPrefix);
        }

        // Resolve the entity scope
        Id resolvedEntityId = resolveLinkedEntityId(params, logPrefix);
        if (resolvedEntityId == null) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'No record context available. Provide linkedEntityId or trigger this agent from a Salesforce record.',
                'Call with linkedEntityId set to the Salesforce ID of the record whose files you want to read.'
            );
        }

        // Query ContentDocumentLink for that entity
        List<ContentDocumentLink> links;
        try {
            links = [
                SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileType, ContentDocument.ContentSize
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :resolvedEntityId
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate DESC
                LIMIT :CDL_QUERY_LIMIT
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'ContentDocumentLink query failed: ' + e.getMessage());
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_SOQL_ERROR,
                'Failed to query files for record ' + resolvedEntityId + ': ' + e.getMessage(),
                'Verify the record ID is valid and you have permission to view its files.'
            );
        }

        List<Map<String, Object>> refs = new List<Map<String, Object>>();
        for (ContentDocumentLink link : links) {
            if (link.ContentDocument == null) {
                continue;
            }
            Map<String, Object> ref = new Map<String, Object>{
                'contentDocumentId' => link.ContentDocumentId,
                'title' => link.ContentDocument.Title,
                'fileType' => link.ContentDocument.FileType,
                'sizeBytes' => link.ContentDocument.ContentSize != null ? (Long) link.ContentDocument.ContentSize : 0L
            };
            refs.add(ref);
        }

        if (refs.isEmpty()) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND,
                'No files found attached to record ' + resolvedEntityId + '.',
                'Upload a file to this record first, or provide a different linkedEntityId.'
            );
        }

        // Single file — read it automatically
        if (refs.size() == 1) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Single file found. Reading automatically: ' + refs[0].get('title'));
            return readAndReturnFile((String) refs[0].get('contentDocumentId'), String.valueOf(resolvedEntityId), logPrefix);
        }

        // Multiple files — return disambiguation list so the LLM can pick one
        Map<String, Object> disambiguation = new Map<String, Object>{
            'action' => 'disambiguation_required',
            'message' => refs.size() + ' files are attached to this record. Call again with contentDocumentId to read a specific file.',
            'files' => refs
        };
        System.debug(LoggingLevel.INFO, logPrefix + 'Returning disambiguation list. File count: ' + refs.size());
        return ActionOutcome.success(disambiguation);
    }

    private Id resolveLinkedEntityId(Map<String, Object> params, String logPrefix) {
        String providedId = extractOptionalId(params, 'linkedEntityId', logPrefix);
        if (String.isNotBlank(providedId)) {
            try {
                return Id.valueOf(providedId);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Invalid linkedEntityId "' + providedId + '": ' + e.getMessage());
            }
        }

        if (this.actionContext?.relatedRecordId != null) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Falling back to actionContext.relatedRecordId: ' + this.actionContext.relatedRecordId);
            return this.actionContext.relatedRecordId;
        }

        return null;
    }

    // ─── by_file_id path ─────────────────────────────────────────────────────────

    private ActionOutcome executeByFileId(Map<String, Object> params, String logPrefix) {
        Object docIdRaw = params.get('contentDocumentId');
        if (docIdRaw == null) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'contentDocumentId is required for this tool.',
                'Provide the Salesforce ContentDocument ID of the file to read. File IDs are shown in the email attachment list.'
            );
        }

        String docId = String.valueOf(docIdRaw).trim();
        try {
            Id.valueOf(docId);
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid contentDocumentId: "' + docId + '".',
                'Provide a valid 15- or 18-character Salesforce ContentDocument ID.'
            );
        }

        return readAndReturnFile(docId, null, logPrefix);
    }

    // ─── Shared file reading ──────────────────────────────────────────────────────

    private ActionOutcome readAndReturnFile(String contentDocumentId, String linkedEntityId, String logPrefix) {
        // Fetch the latest version
        List<ContentVersion> versions;
        try {
            versions = [
                SELECT VersionData, FileType, FileExtension, Title, ContentSize
                FROM ContentVersion
                WHERE ContentDocumentId = :contentDocumentId AND IsLatest = TRUE
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'ContentVersion query failed: ' + e.getMessage());
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_SOQL_ERROR,
                'Failed to retrieve file: ' + e.getMessage(),
                'Verify the file ID is correct and you have permission to read this file.'
            );
        }

        if (versions.isEmpty()) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND,
                'File not found for ContentDocument ID: ' + contentDocumentId + '.',
                'Verify the file ID is correct and the file has not been deleted.'
            );
        }

        ContentVersion cv = versions[0];

        // Extension allowlist check (only when configured)
        if (config.allowedFileExtensions != null && !config.allowedFileExtensions.isEmpty()) {
            String ext = String.isNotBlank(cv.FileExtension) ? cv.FileExtension.toLowerCase().trim() : '';
            Set<String> allowed = new Set<String>();
            for (String s : config.allowedFileExtensions) {
                if (String.isNotBlank(s)) {
                    allowed.add(s.toLowerCase().trim());
                }
            }
            if (!allowed.contains(ext)) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'File type "' +
                        (String.isNotBlank(cv.FileExtension) ? cv.FileExtension : 'unknown') +
                        '" is not permitted for this capability. Allowed types: ' +
                        String.join(new List<String>(allowed), ', ') +
                        '.',
                    'Ask the user to share a file with one of the permitted extensions, or contact your administrator to update the allowed file type list.'
                );
            }
        }

        // Size check
        Long fileSize = cv.ContentSize != null ? (Long) cv.ContentSize : 0L;
        Long maxBytes = (long) config.maxFileSizeKb * 1024L;
        if (fileSize > maxBytes) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'File "' + cv.Title + '" is too large (' + (fileSize / 1024) + ' KB). The maximum size for this capability is ' + config.maxFileSizeKb + ' KB.',
                'Ask the user to provide a smaller file or a subset of the data (e.g. first 100 rows of the spreadsheet).'
            );
        }

        String fileType = String.isNotBlank(cv.FileType) ? cv.FileType.toUpperCase() : null;
        String fileExtension = String.isNotBlank(cv.FileExtension) ? cv.FileExtension.toUpperCase() : null;

        if (shouldTreatAsText(fileType, fileExtension)) {
            String content;
            try {
                content = cv.VersionData.toString();
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Blob.toString() failed for text file "' + cv.Title + '": ' + e.getMessage());
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'Could not decode "' + cv.Title + '" as UTF-8 text.',
                    'Ask the user to save the file with UTF-8 encoding or export it as plain text, CSV, or JSON.'
                );
            }

            Map<String, Object> result = new Map<String, Object>{
                'filename' => cv.Title,
                'fileType' => cv.FileType,
                'sizeBytes' => fileSize,
                'linkedEntityId' => linkedEntityId,
                'content' => content
            };

            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully read text file "' + cv.Title + '" (' + fileSize + ' bytes).');
            return ActionOutcome.success(result);
        }

        if (shouldTreatAsVisionBinary(fileType, fileExtension)) {
            String mimeType = getMimeType(fileType, fileExtension);
            Map<String, Object> binaryResult = new Map<String, Object>{
                'filename' => cv.Title,
                'fileType' => cv.FileType,
                'sizeBytes' => fileSize,
                'linkedEntityId' => linkedEntityId,
                'multimodal' => new Map<String, Object>{ 'mimeType' => mimeType, 'base64' => EncodingUtil.base64Encode(cv.VersionData) }
            };
            System.debug(LoggingLevel.INFO, logPrefix + 'Returning image file "' + cv.Title + '" as multimodal payload (' + mimeType + ').');
            return ActionOutcome.success(binaryResult);
        }

        return ActionOutcome.failure(
            AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
            'The file format "' +
                (String.isNotBlank(cv.FileExtension) ? cv.FileExtension : (String.isNotBlank(cv.FileType) ? cv.FileType : 'unknown')) +
                '" is not supported for analysis.',
            'Supported text formats include TXT, CSV, JSON, XML, HTML, MD, LOG, YAML. Supported image formats for vision analysis are PNG, JPG, GIF, and WEBP.'
        );
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    private String extractOptionalId(Map<String, Object> params, String key, String logPrefix) {
        Object raw = params.get(key);
        if (raw == null) {
            return null;
        }
        String val = String.valueOf(raw).trim();
        if (String.isBlank(val)) {
            return null;
        }
        try {
            Id.valueOf(val);
            return val;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Invalid ID for "' + key + '": ' + val);
            return null;
        }
    }

    /**
     * Maps a Salesforce FileType value to the MIME type needed for a base64 data URL.
     * Returns null for formats that are not supported for vision analysis, which causes
     * the caller to fall through to the generic "unsupported format" failure.
     */
    @TestVisible
    private static String getMimeType(String fileType, String fileExtension) {
        String normalizedType = String.isNotBlank(fileType) ? fileType.toUpperCase() : null;
        String normalizedExtension = String.isNotBlank(fileExtension) ? fileExtension.toUpperCase() : null;
        String probe = String.isNotBlank(normalizedType) ? normalizedType : normalizedExtension;
        if (String.isBlank(probe)) {
            return null;
        }
        switch on probe {
            when 'PNG' {
                return 'image/png';
            }
            when 'JPG', 'JPEG' {
                return 'image/jpeg';
            }
            when 'GIF' {
                return 'image/gif';
            }
            when 'WEBP' {
                return 'image/webp';
            }
            when else {
                return null;
            }
        }
    }

    @TestVisible
    private static Boolean shouldTreatAsText(String fileType, String fileExtension) {
        String normalizedType = String.isNotBlank(fileType) ? fileType.toUpperCase() : null;
        String normalizedExtension = String.isNotBlank(fileExtension) ? fileExtension.toUpperCase() : null;

        Set<String> textTypes = new Set<String>{ 'TXT', 'TEXT', 'CSV', 'JSON', 'XML', 'HTML', 'HTM', 'MD', 'LOG', 'YAML', 'YML' };
        if (String.isNotBlank(normalizedType) && textTypes.contains(normalizedType)) {
            return true;
        }
        return String.isNotBlank(normalizedExtension) && textTypes.contains(normalizedExtension);
    }

    @TestVisible
    private static Boolean shouldTreatAsVisionBinary(String fileType, String fileExtension) {
        return String.isNotBlank(getMimeType(fileType, fileExtension));
    }
}
