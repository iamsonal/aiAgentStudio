/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

@IsTest
private class ActionHttpCalloutTest {
    // ===== MOCK HTTP CLIENTS =====

    private class MockHttpClient implements ActionHttpCallout.IHttpClient {
        public Integer statusCode;
        public String status;
        public String responseBody;

        public MockHttpClient(Integer statusCode, String status, String responseBody) {
            this.statusCode = statusCode;
            this.status = status;
            this.responseBody = responseBody;
        }

        public HttpResponse send(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setStatus(status);
            if (String.isNotBlank(responseBody)) {
                res.setBody(responseBody);
            }
            return res;
        }
    }

    private class CapturingHttpClient implements ActionHttpCallout.IHttpClient {
        public HttpRequest lastRequest;
        public Integer statusCode = 200;
        public String responseBody = '{"ok":true}';

        public HttpResponse send(HttpRequest req) {
            this.lastRequest = req;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setStatus('OK');
            res.setBody(responseBody);
            return res;
        }
    }

    // ===== HELPERS =====

    private static ActionHttpCallout buildAction(String configJson, ActionHttpCallout.IHttpClient mockClient) {
        ActionHttpCallout action = new ActionHttpCallout();
        action.httpClient = mockClient;
        action.parseActionConfiguration(configJson, '[Test]');
        return action;
    }

    private static String cfg(String namedCredential, String endpoint, String method) {
        return '{"namedCredential":"' + namedCredential + '","endpoint":"' + endpoint + '","method":"' + method + '"}';
    }

    // ===== CONFIGURATION VALIDATION =====

    @IsTest
    static void testParseConfig_MissingAll_ThrowsValidation() {
        ActionHttpCallout action = new ActionHttpCallout();
        try {
            action.parseActionConfiguration(null, '[Test]');
            System.assert(false, 'Expected ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('required'), 'Expected required field error');
        }
    }

    @IsTest
    static void testParseConfig_MissingNamedCredential_ThrowsValidation() {
        ActionHttpCallout action = new ActionHttpCallout();
        try {
            action.parseActionConfiguration('{"endpoint":"/v1/test","method":"GET"}', '[Test]');
            System.assert(false, 'Expected ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('namedCredential'), 'Expected namedCredential error');
        }
    }

    @IsTest
    static void testParseConfig_InvalidMethod_ThrowsValidation() {
        ActionHttpCallout action = new ActionHttpCallout();
        try {
            action.parseActionConfiguration('{"namedCredential":"MyCred","endpoint":"/v1/test","method":"CONNECT"}', '[Test]');
            System.assert(false, 'Expected ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('method'), 'Expected method error');
        }
    }

    @IsTest
    static void testParseConfig_EndpointWithoutLeadingSlash_ThrowsValidation() {
        ActionHttpCallout action = new ActionHttpCallout();
        try {
            action.parseActionConfiguration('{"namedCredential":"MyCred","endpoint":"v1/test","method":"GET"}', '[Test]');
            System.assert(false, 'Expected ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('endpoint'), 'Expected endpoint error');
        }
    }

    @IsTest
    static void testParseConfig_TimeoutOverMax_StillSucceeds() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction('{"namedCredential":"MyCred","endpoint":"/v1/test","method":"GET","timeout":999999}', mock);
        ActionOutcome result = action.executeAction(new Map<String, Object>());
        System.assert(result.isSuccess, 'Action should still succeed after timeout cap is applied');
    }

    @IsTest
    static void testParseConfig_MethodCaseInsensitive() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/test', 'get'), mock);
        action.executeAction(new Map<String, Object>());
        System.assertEquals('GET', mock.lastRequest.getMethod(), 'Method should be uppercased');
    }

    // ===== GET REQUEST =====

    @IsTest
    static void testGet_Success_ReturnsJsonBody() {
        MockHttpClient mock = new MockHttpClient(200, 'OK', '{"id":"123","name":"Test"}');
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/items', 'GET'), mock);

        ActionOutcome result = action.executeAction(new Map<String, Object>());

        System.assert(result.isSuccess, 'Expected success');
        Map<String, Object> body = (Map<String, Object>) ((Map<String, Object>) result.data).get('body');
        System.assertEquals('123', body.get('id'));
    }

    @IsTest
    static void testGet_WithPathVariables_ResolvesTemplate() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/cases/{caseId}', 'GET'), mock);

        action.executeAction(new Map<String, Object>{ 'pathVariables' => new Map<String, Object>{ 'caseId' => '500ABC123' } });

        System.assert(mock.lastRequest.getEndpoint().contains('/v1/cases/500ABC123'), 'Path variable should be substituted');
    }

    @IsTest
    static void testGet_PathVariableUrlEncoded() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/search/{term}', 'GET'), mock);

        action.executeAction(new Map<String, Object>{ 'pathVariables' => new Map<String, Object>{ 'term' => 'hello world' } });

        System.assert(mock.lastRequest.getEndpoint().contains('hello+world'), 'Path variable should be URL-encoded');
    }

    @IsTest
    static void testGet_WithQueryParams_AppendedToUrl() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/items', 'GET'), mock);

        action.executeAction(new Map<String, Object>{ 'queryParams' => new Map<String, Object>{ 'status' => 'active', 'limit' => '10' } });

        String endpoint = mock.lastRequest.getEndpoint();
        System.assert(endpoint.contains('status=active'), 'Query param status should be present');
        System.assert(endpoint.contains('limit=10'), 'Query param limit should be present');
    }

    @IsTest
    static void testGet_StaticAndRuntimeQueryParamsMerged() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(
            '{"namedCredential":"MyCred","endpoint":"/v1/items","method":"GET","staticQueryParams":{"version":"2.0"}}',
            mock
        );

        action.executeAction(new Map<String, Object>{ 'queryParams' => new Map<String, Object>{ 'filter' => 'open' } });

        String endpoint = mock.lastRequest.getEndpoint();
        System.assert(endpoint.contains('version=2.0'), 'Static query param should be present');
        System.assert(endpoint.contains('filter=open'), 'Runtime query param should be present');
    }

    @IsTest
    static void testGet_BodyIgnored() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/items', 'GET'), mock);

        action.executeAction(new Map<String, Object>{ 'body' => new Map<String, Object>{ 'key' => 'val' } });

        System.assert(String.isBlank(mock.lastRequest.getBody()), 'GET body should be empty for GET requests');
    }

    @IsTest
    static void testGet_UnresolvedPlaceholder_ReturnsValidationFailure() {
        MockHttpClient mock = new MockHttpClient(200, 'OK', '{}');
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/cases/{caseId}', 'GET'), mock);

        ActionOutcome result = action.executeAction(new Map<String, Object>());

        System.assert(!result.isSuccess, 'Expected failure for unresolved placeholder');
        System.assert(result.errorCode.contains('INPUT_VALIDATION'), 'Expected INPUT_VALIDATION error');
    }

    // ===== POST REQUEST =====

    @IsTest
    static void testPost_WithObjectBody_SerializesToJson() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/cases', 'POST'), mock);

        action.executeAction(new Map<String, Object>{ 'body' => new Map<String, Object>{ 'subject' => 'Test Issue', 'priority' => 'High' } });

        String body = mock.lastRequest.getBody();
        System.assert(body.contains('"subject"'), 'Body should contain subject field');
        System.assert(body.contains('Test Issue'), 'Body should contain subject value');
        System.assertEquals('application/json', mock.lastRequest.getHeader('Content-Type'), 'Default Content-Type should be set');
    }

    @IsTest
    static void testPost_WithStringBody_UsedAsIs() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/cases', 'POST'), mock);

        String rawBody = '{"custom":"payload"}';
        action.executeAction(new Map<String, Object>{ 'body' => rawBody });

        System.assertEquals(rawBody, mock.lastRequest.getBody(), 'String body should be used as-is');
    }

    @IsTest
    static void testPost_ContentTypeHeaderFromConfig_NotOverridden() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(
            '{"namedCredential":"MyCred","endpoint":"/v1/test","method":"POST","headers":{"Content-Type":"application/xml"}}',
            mock
        );

        action.executeAction(new Map<String, Object>{ 'body' => '<root/>' });

        System.assertEquals('application/xml', mock.lastRequest.getHeader('Content-Type'), 'Config Content-Type should take precedence');
    }

    @IsTest
    static void testPost_StaticHeadersSent() {
        CapturingHttpClient mock = new CapturingHttpClient();
        ActionHttpCallout action = buildAction(
            '{"namedCredential":"MyCred","endpoint":"/v1/test","method":"POST","headers":{"X-Custom-Header":"abc123"}}',
            mock
        );

        action.executeAction(new Map<String, Object>());

        System.assertEquals('abc123', mock.lastRequest.getHeader('X-Custom-Header'), 'Static header should be sent');
    }

    // ===== HTTP ERROR RESPONSES =====

    @IsTest
    static void testHttp404_ReturnsFailureWithDetails() {
        MockHttpClient mock = new MockHttpClient(404, 'Not Found', '{"error":"Record not found"}');
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/cases/999', 'GET'), mock);

        ActionOutcome result = action.executeAction(new Map<String, Object>());

        System.assert(!result.isSuccess, 'Expected failure for 404');
        System.assert(result.errorMessage.contains('404'), 'Error should mention 404');
    }

    @IsTest
    static void testHttp500_ReturnsFailure() {
        MockHttpClient mock = new MockHttpClient(500, 'Internal Server Error', '{"error":"Server error"}');
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/test', 'GET'), mock);

        ActionOutcome result = action.executeAction(new Map<String, Object>());

        System.assert(!result.isSuccess, 'Expected failure for 500');
    }

    @IsTest
    static void testHttp201_TreatedAsSuccess() {
        MockHttpClient mock = new MockHttpClient(201, 'Created', '{"id":"new-123"}');
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/cases', 'POST'), mock);

        ActionOutcome result = action.executeAction(new Map<String, Object>());

        System.assert(result.isSuccess, 'Expected success for 201 Created');
    }

    // ===== RESPONSE BODY HANDLING =====

    @IsTest
    static void testNonJsonResponse_ReturnedAsString() {
        MockHttpClient mock = new MockHttpClient(200, 'OK', 'plain text response');
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/test', 'GET'), mock);

        ActionOutcome result = action.executeAction(new Map<String, Object>());

        System.assert(result.isSuccess, 'Expected success');
        Map<String, Object> outcome = (Map<String, Object>) result.data;
        System.assertEquals('plain text response', outcome.get('body'), 'Non-JSON body should be returned as string');
    }

    @IsTest
    static void testEmptyResponseBody_HandledGracefully() {
        MockHttpClient mock = new MockHttpClient(204, 'No Content', null);
        ActionHttpCallout action = buildAction(cfg('MyCred', '/v1/test', 'DELETE'), mock);

        ActionOutcome result = action.executeAction(new Map<String, Object>());

        System.assert(result.isSuccess, 'Expected success for 204 No Content');
        Map<String, Object> outcome = (Map<String, Object>) result.data;
        System.assertEquals(204, (Integer) outcome.get('statusCode'));
    }

    // ===== HELPER UNIT TESTS =====

    @IsTest
    static void testResolveTemplate_SinglePlaceholder() {
        ActionHttpCallout action = new ActionHttpCallout();
        action.parseActionConfiguration(cfg('C', '/v1/{id}', 'GET'), '[Test]');
        String result = action.resolveTemplate('/v1/{id}', new Map<String, Object>{ 'id' => '123' });
        System.assertEquals('/v1/123', result);
    }

    @IsTest
    static void testResolveTemplate_MultiplePlaceholders() {
        ActionHttpCallout action = new ActionHttpCallout();
        action.parseActionConfiguration(cfg('C', '/v1/{obj}/{id}', 'GET'), '[Test]');
        String result = action.resolveTemplate('/v1/{obj}/{id}', new Map<String, Object>{ 'obj' => 'cases', 'id' => '500' });
        System.assertEquals('/v1/cases/500', result);
    }

    @IsTest
    static void testBuildQueryString_EmptyInputs_ReturnsEmpty() {
        ActionHttpCallout action = new ActionHttpCallout();
        action.parseActionConfiguration(cfg('C', '/v1/test', 'GET'), '[Test]');
        String result = action.buildQueryString(null, null);
        System.assertEquals('', result);
    }
}
