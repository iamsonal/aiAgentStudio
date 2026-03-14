/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Unit tests for ActionAnalyzeFile.
 *
 * Coverage:
 *  - from_record: single file auto-read
 *  - from_record: disambiguation when multiple files are attached
 *  - from_record: contentDocumentId shortcut bypasses ContentDocumentLink query
 *  - from_record: relatedRecordId fallback when no linkedEntityId is in params
 *  - from_record: no entity context returns structured failure
 *  - by_file_id: direct contentDocumentId read
 *  - by_file_id: missing contentDocumentId returns failure
 *  - Size rejection: file exceeds maxFileSizeKb ceiling
 *  - Extension allowlist: file type blocked when allowedFileExtensions is configured
 *  - Extension allowlist: file type passes when extension matches allowlist
 *  - Not found: no ContentDocumentLink records
 *  - Not found: no ContentVersion record for given contentDocumentId
 */
@IsTest
private class ActionAnalyzeFileTest {
    private static final String CSV_CONTENT = 'Date,Amount\n2025-01-01,100.00\n2025-01-02,200.00';
    private static final String TXT_CONTENT = 'Hello, world! This is a plain text file.';

    // ─── Helpers ───────────────────────────────────────────────────────────────────

    /**
     * Creates a ContentVersion (and implicitly a ContentDocument) attached to the given record.
     * Returns the ContentVersion after insert so callers can access ContentDocumentId.
     */
    private static ContentVersion insertFileOnRecord(Id recordId, String title, String extension, Blob data) {
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.' + extension, VersionData = data, FirstPublishLocationId = recordId);
        insert cv;
        return [SELECT Id, ContentDocumentId, ContentSize FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
    }

    /**
     * Creates a ContentVersion NOT attached to any record (for by_file_id tests where we
     * supply the contentDocumentId directly and do not need ContentDocumentLink).
     */
    private static ContentVersion insertStandaloneFile(String title, String extension, Blob data) {
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.' + extension, VersionData = data);
        insert cv;
        return [SELECT Id, ContentDocumentId, ContentSize FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
    }

    private static ActionContext buildContext(Id relatedRecordId) {
        return new ActionContext(null, UserInfo.getUserId(), UserInfo.getUserId(), relatedRecordId, null, null, null, 'turn-001', 1, 'SingleShot');
    }

    private static ActionAnalyzeFile buildAction(String variant) {
        return buildAction(variant, 50, null);
    }

    private static ActionAnalyzeFile buildAction(String variant, Integer maxKb, List<String> allowedExts) {
        ActionAnalyzeFile action = new ActionAnalyzeFile();
        Map<String, Object> configMap = new Map<String, Object>{ 'variant' => variant, 'maxFileSizeKb' => maxKb };
        if (allowedExts != null) {
            configMap.put('allowedFileExtensions', allowedExts);
        }
        action.parseActionConfiguration(JSON.serialize(configMap), '[TEST] ');
        return action;
    }

    // ─── from_record: single file auto-read ────────────────────────────────────────

    @IsTest
    static void fromRecord_singleFile_returnsContent() {
        Account acc = new Account(Name = 'File Test Corp');
        insert acc;

        ContentVersion cv = insertFileOnRecord(acc.Id, 'report', 'csv', Blob.valueOf(CSV_CONTENT));

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD);
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Single file on record should succeed. Error: ' + (result.isSuccess ? '' : result.errorMessage));
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals('report', data.get('filename'), 'Filename should match');
        System.assertEquals(CSV_CONTENT, data.get('content'), 'Content should match the uploaded CSV');
        System.assertEquals('CSV', data.get('fileType'), 'File type should be CSV');
    }

    // ─── from_record: disambiguation when multiple files ──────────────────────────

    @IsTest
    static void fromRecord_multipleFiles_returnsDisambiguation() {
        Account acc = new Account(Name = 'Multi File Corp');
        insert acc;

        insertFileOnRecord(acc.Id, 'invoice', 'csv', Blob.valueOf(CSV_CONTENT));
        insertFileOnRecord(acc.Id, 'notes', 'txt', Blob.valueOf(TXT_CONTENT));

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD);
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Disambiguation response should be a success outcome.');
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals('disambiguation_required', data.get('action'), 'Action field should signal disambiguation');
        List<Object> files = (List<Object>) data.get('files');
        System.assertNotEquals(null, files, 'files list should be present');
        System.assertEquals(2, files.size(), 'Should list both attached files');
    }

    // ─── from_record: contentDocumentId shortcut ──────────────────────────────────

    @IsTest
    static void fromRecord_contentDocumentIdProvided_skipsLookupAndReadsDirectly() {
        Account acc = new Account(Name = 'Direct ID Corp');
        insert acc;

        // Two files on the record — the tool should read only the one whose ID is provided
        ContentVersion cv1 = insertFileOnRecord(acc.Id, 'target', 'txt', Blob.valueOf(TXT_CONTENT));
        insertFileOnRecord(acc.Id, 'other', 'csv', Blob.valueOf(CSV_CONTENT));

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD);
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id, 'contentDocumentId' => cv1.ContentDocumentId };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Direct ID lookup should succeed.');
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals('target', data.get('filename'), 'Should return the specifically requested file');
        System.assertEquals(TXT_CONTENT, data.get('content'), 'Content should match target file');
    }

    // ─── from_record: relatedRecordId fallback ────────────────────────────────────

    @IsTest
    static void fromRecord_noLinkedEntityIdParam_fallsBackToContextRelatedRecordId() {
        Account acc = new Account(Name = 'Context Fallback Corp');
        insert acc;

        ContentVersion cv = insertFileOnRecord(acc.Id, 'summary', 'txt', Blob.valueOf(TXT_CONTENT));

        // Build action and call via execute() so actionContext.relatedRecordId is set
        ActionAnalyzeFile action = new ActionAnalyzeFile();
        String configJson = JSON.serialize(new Map<String, Object>{ 'variant' => ActionAnalyzeFile.VARIANT_FROM_RECORD, 'maxFileSizeKb' => 50 });
        ActionContext ctx = buildContext(acc.Id);

        Test.startTest();
        // Empty params — no linkedEntityId, no contentDocumentId
        ActionOutcome result = action.execute(configJson, '{}', ctx);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should fall back to actionContext.relatedRecordId. Error: ' + (result.isSuccess ? '' : result.errorMessage));
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals('summary', data.get('filename'));
    }

    // ─── from_record: no entity context ──────────────────────────────────────────

    @IsTest
    static void fromRecord_noEntityContext_returnsFailure() {
        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD);
        Map<String, Object> params = new Map<String, Object>();

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail when no entity context is available');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    // ─── from_record: no files attached ──────────────────────────────────────────

    @IsTest
    static void fromRecord_noFilesAttached_returnsNotFound() {
        Account acc = new Account(Name = 'Empty Record Corp');
        insert acc;

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD);
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail when no files are attached');
        System.assertEquals(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, result.errorCode);
    }

    // ─── by_file_id: direct read ──────────────────────────────────────────────────

    @IsTest
    static void byFileId_validDocumentId_returnsContent() {
        ContentVersion cv = insertStandaloneFile('data', 'txt', Blob.valueOf(TXT_CONTENT));

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_BY_FILE_ID);
        Map<String, Object> params = new Map<String, Object>{ 'contentDocumentId' => cv.ContentDocumentId };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'by_file_id should read file successfully. Error: ' + (result.isSuccess ? '' : result.errorMessage));
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals(TXT_CONTENT, data.get('content'));
        System.assertEquals('data', data.get('filename'));
    }

    // ─── by_file_id: missing contentDocumentId ────────────────────────────────────

    @IsTest
    static void byFileId_missingContentDocumentId_returnsValidationFailure() {
        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_BY_FILE_ID);
        Map<String, Object> params = new Map<String, Object>();

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail when contentDocumentId is not provided');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    // ─── by_file_id: invalid ID format ───────────────────────────────────────────

    @IsTest
    static void byFileId_invalidIdFormat_returnsValidationFailure() {
        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_BY_FILE_ID);
        Map<String, Object> params = new Map<String, Object>{ 'contentDocumentId' => 'not-a-valid-id' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail on malformed ID');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    // ─── by_file_id: file not found ───────────────────────────────────────────────

    @IsTest
    static void byFileId_nonExistentDocumentId_returnsNotFound() {
        // Use a syntactically valid but non-existent ContentDocument ID
        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_BY_FILE_ID);
        Map<String, Object> params = new Map<String, Object>{ 'contentDocumentId' => '069000000000001AAA' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail when no ContentVersion is found for the ID');
        System.assert(
            result.errorCode == AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND || result.errorCode == AIAgentConstants.ERR_CODE_SOQL_ERROR,
            'Error code should indicate not-found or query failure. Got: ' + result.errorCode
        );
    }

    // ─── Size rejection ───────────────────────────────────────────────────────────

    @IsTest
    static void fileTooLarge_returnsValidationFailure() {
        Account acc = new Account(Name = 'Big File Corp');
        insert acc;

        // maxFileSizeKb = 1 KB; any real payload larger than 1 024 bytes should fail
        String bigContent = 'X'.repeat(1200); // 1 200 bytes > 1 024 bytes
        ContentVersion cv = insertFileOnRecord(acc.Id, 'bigfile', 'txt', Blob.valueOf(bigContent));

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD, 1, null);
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should reject file exceeding maxFileSizeKb');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
        System.assert(result.errorMessage.contains('too large'), 'Error message should mention size. Got: ' + result.errorMessage);
    }

    // ─── Extension allowlist: file blocked ────────────────────────────────────────

    @IsTest
    static void allowedFileExtensions_extensionNotInList_returnsFailure() {
        Account acc = new Account(Name = 'Ext Block Corp');
        insert acc;

        // Upload a .txt file but only allow csv
        ContentVersion cv = insertFileOnRecord(acc.Id, 'notes', 'txt', Blob.valueOf(TXT_CONTENT));

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD, 50, new List<String>{ 'csv', 'json' });
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should reject file with extension not in allowedFileExtensions');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
        System.assert(result.errorMessage.contains('not permitted'), 'Error message should mention extension restriction. Got: ' + result.errorMessage);
    }

    // ─── Extension allowlist: file passes ────────────────────────────────────────

    @IsTest
    static void allowedFileExtensions_extensionInList_returnsContent() {
        Account acc = new Account(Name = 'Ext Allow Corp');
        insert acc;

        ContentVersion cv = insertFileOnRecord(acc.Id, 'data', 'csv', Blob.valueOf(CSV_CONTENT));

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD, 50, new List<String>{ 'csv', 'txt' });
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'CSV file should pass when csv is in the allowlist. Error: ' + (result.isSuccess ? '' : result.errorMessage));
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals(CSV_CONTENT, data.get('content'));
    }

    // ─── Default config parsing ────────────────────────────────────────────────────

    @IsTest
    static void parseActionConfiguration_emptyJson_defaultsApplied() {
        ActionAnalyzeFile action = new ActionAnalyzeFile();
        action.parseActionConfiguration(null, '[TEST] ');

        // Re-use the action for a simple no-entity call to verify it doesn't crash on defaults
        Test.startTest();
        ActionOutcome result = action.executeAction(new Map<String, Object>());
        Test.stopTest();

        // With no entity, it should fail gracefully — not throw an unhandled exception
        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    // ─── from_record: linkedEntityId from params overrides context ─────────────────

    @IsTest
    static void fromRecord_linkedEntityIdInParams_overridesContextRelatedRecord() {
        Account contextRecord = new Account(Name = 'Context Record');
        Account targetRecord = new Account(Name = 'Target Record');
        insert new List<Account>{ contextRecord, targetRecord };

        // File is on targetRecord, not contextRecord
        ContentVersion cv = insertFileOnRecord(targetRecord.Id, 'attachment', 'txt', Blob.valueOf(TXT_CONTENT));

        // Context is contextRecord, but params points to targetRecord
        ActionAnalyzeFile action = new ActionAnalyzeFile();
        String configJson = JSON.serialize(new Map<String, Object>{ 'variant' => ActionAnalyzeFile.VARIANT_FROM_RECORD, 'maxFileSizeKb' => 50 });
        ActionContext ctx = buildContext(contextRecord.Id);

        Map<String, Object> paramsMap = new Map<String, Object>{ 'linkedEntityId' => targetRecord.Id };

        Test.startTest();
        ActionOutcome result = action.execute(configJson, JSON.serialize(paramsMap), ctx);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should read file from param-provided linkedEntityId. Error: ' + (result.isSuccess ? '' : result.errorMessage));
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals('attachment', data.get('filename'));
    }

    // ─── Phase 2: binary files — multimodal marker ────────────────────────────────

    /**
     * PNG file (non-UTF-8 bytes) → ActionAnalyzeFile returns an AnalyzeFileResult with a
     * multimodal map containing mimeType and base64, ready for a vision LLM.
     * The PNG magic number bytes (0x89...) are not valid UTF-8, so Blob.toString() throws
     * and the binary branch is taken.
     */
    @IsTest
    static void binaryFile_pngExtension_returnsMultimodalMarker() {
        Account acc = new Account(Name = 'Vision Test Corp');
        insert acc;

        // PNG magic number: 89 50 4E 47 0D 0A 1A 0A — not valid UTF-8
        Blob pngBlob = EncodingUtil.base64Decode('iVBORw0KGgo=');
        ContentVersion cv = insertFileOnRecord(acc.Id, 'screenshot', 'png', pngBlob);

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD, 50, null);
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'PNG file should return success with multimodal marker. Error: ' + (result.isSuccess ? '' : result.errorMessage));
        Map<String, Object> data = (Map<String, Object>) result.data;
        System.assertEquals('screenshot', data.get('filename'), 'Filename should match');
        System.assertEquals('PNG', data.get('fileType'), 'FileType should be PNG');
        System.assertNotEquals(null, data.get('multimodal'), 'multimodal key should be present for binary PNG');

        Map<String, Object> multimodal = (Map<String, Object>) data.get('multimodal');
        System.assertEquals('image/png', multimodal.get('mimeType'), 'MIME type should be image/png');
        System.assertNotEquals(null, multimodal.get('base64'), 'base64 should be present');
        System.assert(String.isNotBlank((String) multimodal.get('base64')), 'base64 should be non-blank');
        System.assertEquals(null, data.get('content'), 'content field should be null for binary files');
    }

    /**
     * A file with an unsupported binary extension (e.g. DOCX) fails with INPUT_VALIDATION
     * because getMimeType() returns null — there is no binary fallback for Office documents.
     */
    @IsTest
    static void binaryFile_unsupportedBinaryFormat_returnsFailure() {
        Account acc = new Account(Name = 'Docx Test Corp');
        insert acc;

        // Non-UTF-8 binary data with a DOCX extension — Word documents use PK zip format
        // PK header: 50 4B 03 04
        Blob docxBlob = EncodingUtil.base64Decode('UEsDBBQ=');
        ContentVersion cv = insertFileOnRecord(acc.Id, 'report', 'docx', docxBlob);

        ActionAnalyzeFile action = buildAction(ActionAnalyzeFile.VARIANT_FROM_RECORD, 50, null);
        Map<String, Object> params = new Map<String, Object>{ 'linkedEntityId' => acc.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'DOCX file should fail — no vision support for Office documents');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode, 'Error code should be INPUT_VALIDATION');
    }

    // ─── getMimeType helper ───────────────────────────────────────────────────────

    @IsTest
    static void getMimeType_knownTypes_returnCorrectMimeType() {
        System.assertEquals('image/png', ActionAnalyzeFile.getMimeType('PNG', null));
        System.assertEquals('image/png', ActionAnalyzeFile.getMimeType(null, 'png'));
        System.assertEquals('image/jpeg', ActionAnalyzeFile.getMimeType('JPG', null));
        System.assertEquals('image/jpeg', ActionAnalyzeFile.getMimeType(null, 'JPEG'));
        System.assertEquals('image/gif', ActionAnalyzeFile.getMimeType('GIF', null));
        System.assertEquals('image/webp', ActionAnalyzeFile.getMimeType(null, 'WEBP'));
    }

    @IsTest
    static void getMimeType_unknownTypes_returnNull() {
        System.assertEquals(null, ActionAnalyzeFile.getMimeType('DOCX', null));
        System.assertEquals(null, ActionAnalyzeFile.getMimeType(null, 'XLSX'));
        System.assertEquals(null, ActionAnalyzeFile.getMimeType('ZIP', null));
        System.assertEquals(null, ActionAnalyzeFile.getMimeType(null, 'PDF'));
        System.assertEquals(null, ActionAnalyzeFile.getMimeType(null, null));
        System.assertEquals(null, ActionAnalyzeFile.getMimeType('', ''));
    }

    @IsTest
    static void shouldTreatAsText_knownTypes_returnTrue() {
        System.assertEquals(true, ActionAnalyzeFile.shouldTreatAsText('CSV', null));
        System.assertEquals(true, ActionAnalyzeFile.shouldTreatAsText('TEXT', null));
        System.assertEquals(true, ActionAnalyzeFile.shouldTreatAsText(null, 'json'));
        System.assertEquals(true, ActionAnalyzeFile.shouldTreatAsText(null, 'md'));
    }

    @IsTest
    static void shouldTreatAsText_unknownTypes_returnFalse() {
        System.assertEquals(false, ActionAnalyzeFile.shouldTreatAsText('PNG', null));
        System.assertEquals(false, ActionAnalyzeFile.shouldTreatAsText(null, 'pdf'));
        System.assertEquals(false, ActionAnalyzeFile.shouldTreatAsText(null, 'docx'));
    }

    @IsTest
    static void shouldTreatAsVisionBinary_knownImageTypes_returnTrue() {
        System.assertEquals(true, ActionAnalyzeFile.shouldTreatAsVisionBinary('PNG', null));
        System.assertEquals(true, ActionAnalyzeFile.shouldTreatAsVisionBinary(null, 'jpg'));
        System.assertEquals(true, ActionAnalyzeFile.shouldTreatAsVisionBinary('WEBP', null));
    }

    @IsTest
    static void shouldTreatAsVisionBinary_nonImageTypes_returnFalse() {
        System.assertEquals(false, ActionAnalyzeFile.shouldTreatAsVisionBinary('PDF', null));
        System.assertEquals(false, ActionAnalyzeFile.shouldTreatAsVisionBinary(null, 'csv'));
        System.assertEquals(false, ActionAnalyzeFile.shouldTreatAsVisionBinary('DOCX', null));
    }

    // ─── LLMFormattingService.buildToolResultContent ──────────────────────────────

    @IsTest
    static void buildToolResultContent_noMultimodalKey_returnsOriginalString() {
        String toolResult = '{"success":true,"data":{"filename":"notes.txt","content":"hello"}}';
        Object result = LLMFormattingService.buildToolResultContent(toolResult, true, '[TEST] ');
        System.assert(result instanceof String, 'Should return original string when no _multimodal key');
        System.assertEquals(toolResult, (String) result);
    }

    @IsTest
    static void buildToolResultContent_multimodalPresentVisionTrue_returnsContentArray() {
        Map<String, Object> multimodal = new Map<String, Object>{ 'mimeType' => 'image/png', 'base64' => 'abc123' };
        Map<String, Object> data = new Map<String, Object>{ 'filename' => 'photo.png', 'fileType' => 'PNG', 'multimodal' => multimodal };
        String toolResult = JSON.serialize(new Map<String, Object>{ 'success' => true, 'data' => data });

        Object result = LLMFormattingService.buildToolResultContent(toolResult, true, '[TEST] ');

        System.assert(result instanceof List<Object>, 'Should return content array for vision LLM');
        List<Object> parts = (List<Object>) result;
        System.assertEquals(2, parts.size(), 'Content array should have 2 parts: text + image_url');

        Map<String, Object> textPart = (Map<String, Object>) parts[0];
        System.assertEquals('text', textPart.get('type'));
        String textContent = (String) textPart.get('text');
        System.assert(!textContent.contains('"multimodal"'), 'Text part should NOT include the multimodal blob');
        System.assert(textContent.contains('"filename"'), 'Text part should still include file metadata');

        Map<String, Object> imagePart = (Map<String, Object>) parts[1];
        System.assertEquals('image_url', imagePart.get('type'));
        Map<String, Object> imageUrl = (Map<String, Object>) imagePart.get('image_url');
        System.assert(((String) imageUrl.get('url')).startsWith('data:image/png;base64,'), 'Image URL should be a data URL');
        System.assert(((String) imageUrl.get('url')).contains('abc123'), 'Image URL should contain the base64 data');
    }

    @IsTest
    static void buildToolResultContent_multimodalPresentVisionFalse_returnsPlainStringWithNote() {
        Map<String, Object> multimodal = new Map<String, Object>{ 'mimeType' => 'image/png', 'base64' => 'abc123' };
        Map<String, Object> data = new Map<String, Object>{ 'filename' => 'photo.png', 'multimodal' => multimodal };
        String toolResult = JSON.serialize(new Map<String, Object>{ 'success' => true, 'data' => data });

        Object result = LLMFormattingService.buildToolResultContent(toolResult, false, '[TEST] ');

        System.assert(result instanceof String, 'Should return a plain string for non-vision LLM');
        String resultStr = (String) result;
        System.assert(!resultStr.contains('"multimodal"'), 'Result should not contain the binary blob');
        System.assert(resultStr.contains('_note'), 'Result should contain advisory note about vision capability');
        System.assert(resultStr.contains('SupportsVision__c'), 'Note should guide admin to enable vision');
    }

    @IsTest
    static void buildToolResultContent_nonImageMimeType_returnsPlainStringEvenWhenVisionTrue() {
        Map<String, Object> multimodal = new Map<String, Object>{ 'mimeType' => 'application/pdf', 'base64' => 'abc123' };
        Map<String, Object> data = new Map<String, Object>{ 'filename' => 'doc.pdf', 'multimodal' => multimodal };
        String toolResult = JSON.serialize(new Map<String, Object>{ 'success' => true, 'data' => data });

        Object result = LLMFormattingService.buildToolResultContent(toolResult, true, '[TEST] ');

        System.assert(result instanceof String, 'Non-image MIME types should not be emitted as image_url content arrays');
        String resultStr = (String) result;
        System.assert(!resultStr.contains('"multimodal"'), 'Result should not contain the multimodal blob');
        System.assert(resultStr.contains('_note'), 'Fallback string should include advisory note');
    }

    @IsTest
    static void buildToolResultContent_failureOutcome_returnsOriginalString() {
        String toolResult = '{"success":false,"code":"INPUT_VALIDATION","error":"File too large"}';
        Object result = LLMFormattingService.buildToolResultContent(toolResult, true, '[TEST] ');
        System.assert(result instanceof String, 'Failure outcomes should be returned as-is');
        System.assertEquals(toolResult, (String) result);
    }

    @IsTest
    static void buildToolResultContent_invalidJson_returnsOriginalString() {
        String toolResult = 'not valid json at all';
        Object result = LLMFormattingService.buildToolResultContent(toolResult, true, '[TEST] ');
        System.assert(result instanceof String, 'Invalid JSON should be returned as-is without throwing');
        System.assertEquals(toolResult, (String) result);
    }
}
