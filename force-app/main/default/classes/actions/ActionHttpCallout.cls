/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Makes an authenticated HTTP callout to an external REST API using a Salesforce Named Credential.
 *
 * The Named Credential controls the base URL and authentication — the LLM never has access to
 * credentials or secrets. The admin pins a specific endpoint + method per capability; the LLM
 * only supplies runtime values (path variables, query parameters, request body).
 *
 * Supports GET, POST, PUT, PATCH, and DELETE. For GET and DELETE, any supplied body is ignored.
 * Path variables are URL-encoded before substitution to prevent injection.
 *
 * @ActionLabel HTTP Callout
 * @ActionDescription Makes an authenticated HTTP callout to an external REST API using a Named Credential
 * @ActionRequiresSObject false
 * @ActionIsActive true
 * @ActionIsStandard true
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionHttpCallout extends BaseAgentAction {
    private static final Integer DEFAULT_TIMEOUT_MS = 10000;
    private static final Integer MAX_TIMEOUT_MS = 120000;
    private static final Set<String> VALID_METHODS = new Set<String>{ 'GET', 'POST', 'PUT', 'PATCH', 'DELETE' };
    private static final Set<String> BODY_METHODS = new Set<String>{ 'POST', 'PUT', 'PATCH' };

    @TestVisible
    private IHttpClient httpClient = new DefaultHttpClient();

    private ConfigDTO config;

    // ===== DTOs =====

    public class ConfigDTO {
        /**
         * @FieldLabel Named Credential
         * @FieldType string
         * @FieldRequired true
         * @FieldPlaceholder My_External_API
         * @FieldHelp API name of the Salesforce Named Credential to use (e.g., "My_External_API"). The Named Credential supplies the base URL and handles all authentication — credentials are never exposed to the LLM.
         */
        public String namedCredential;

        /**
         * @FieldLabel Endpoint Path
         * @FieldType string
         * @FieldRequired true
         * @FieldPlaceholder /api/v1/cases/{caseId}
         * @FieldHelp Relative path appended to the Named Credential base URL. Supports {placeholder} tokens that the LLM fills at runtime via pathVariables (e.g., "/v1/cases/{caseId}/comments"). Must start with "/".
         */
        public String endpoint;

        /**
         * @FieldLabel HTTP Method
         * @FieldType string
         * @FieldRequired true
         * @FieldPicklistValues GET,POST,PUT,PATCH,DELETE
         * @FieldHelp HTTP verb for this capability. GET and DELETE ignore the body parameter; POST, PUT, and PATCH accept a JSON body from the LLM.
         */
        public String method;

        /**
         * @FieldLabel Request Headers
         * @FieldType object
         * @FieldRequired false
         * @FieldHelp Static headers sent with every request as a JSON object (e.g., {"Accept": "application/json", "X-Api-Version": "2.0"}). Authentication headers come from the Named Credential automatically. Content-Type defaults to "application/json" for body-bearing methods if not set here.
         */
        public Map<String, String> headers;

        /**
         * @FieldLabel Static Query Parameters
         * @FieldType object
         * @FieldRequired false
         * @FieldHelp Key-value query parameters always appended to the URL as a JSON object (e.g., {"api_version": "2.0", "format": "json"}). Merged with any queryParams the LLM provides at runtime.
         */
        public Map<String, String> staticQueryParams;

        /**
         * @FieldLabel Timeout (ms)
         * @FieldType integer
         * @FieldRequired false
         * @FieldHelp Request timeout in milliseconds. Default 10000 (10 s), maximum 120000 (120 s).
         * @FieldMinValue 1
         * @FieldMaxValue 120000
         */
        public Integer timeout;
    }

    public class ArgumentsDTO {
        /**
         * @FieldLabel Path Variables
         * @FieldType object
         * @FieldRequired false
         * @FieldHelp Key-value pairs that substitute {placeholder} tokens in the endpoint path. Values are URL-encoded automatically (e.g., {"caseId": "500ABC123"} fills /cases/{caseId}).
         */
        public Map<String, Object> pathVariables;

        /**
         * @FieldLabel Query Parameters
         * @FieldType object
         * @FieldRequired false
         * @FieldHelp Dynamic query parameters appended to the URL at runtime. Merged with Static Query Parameters from backend config. Duplicate keys from runtime override static values.
         */
        public Map<String, Object> queryParams;

        /**
         * @FieldLabel Request Body
         * @FieldType object
         * @FieldRequired false
         * @FieldHelp Structured JSON payload for POST, PUT, and PATCH requests. Serialized to a JSON string automatically. For GET and DELETE this parameter is ignored.
         */
        public Object body;
    }

    // ===== EXECUTION =====

    public override ActionOutcome executeAction(Map<String, Object> params) {
        Map<String, Object> pathVariables = ActionConfigUtils.getOptionalMap(params, 'pathVariables');
        Map<String, Object> queryParams = ActionConfigUtils.getOptionalMap(params, 'queryParams');
        Object bodyParam = params.get('body');

        // Resolve path template
        String resolvedPath = resolveTemplate(config.endpoint, pathVariables);

        if (hasUnresolvedPlaceholders(resolvedPath)) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Endpoint contains unresolved placeholders: "' + resolvedPath + '". Supply values for every {token} via pathVariables.'
            );
        }

        // Build full URL
        String queryString = buildQueryString(config.staticQueryParams, queryParams);
        String url = 'callout:' + config.namedCredential + resolvedPath;
        if (String.isNotBlank(queryString)) {
            url += '?' + queryString;
        }

        // Build request
        HttpRequest req = new HttpRequest();
        req.setEndpoint(url);
        req.setMethod(config.method);
        req.setTimeout(config.timeout != null ? config.timeout : DEFAULT_TIMEOUT_MS);

        // Apply static headers
        if (config.headers != null) {
            for (String name : config.headers.keySet()) {
                req.setHeader(name, config.headers.get(name));
            }
        }

        // Set body for mutating methods
        if (BODY_METHODS.contains(config.method) && bodyParam != null) {
            String bodyStr;
            if (bodyParam instanceof String) {
                bodyStr = (String) bodyParam;
            } else {
                bodyStr = JSON.serialize(bodyParam);
            }
            req.setBody(bodyStr);
            if (req.getHeader('Content-Type') == null) {
                req.setHeader('Content-Type', 'application/json');
            }
        }

        TransactionContext.getInstance().markUnsafeOperation('HTTP callout via ActionHttpCallout to ' + config.namedCredential);

        try {
            HttpResponse res = httpClient.send(req);
            return buildOutcome(res, url);
        } catch (System.CalloutException ce) {
            return ActionOutcome.fromException(ce);
        }
    }

    private ActionOutcome buildOutcome(HttpResponse res, String url) {
        Integer statusCode = res.getStatusCode();
        String responseBody = res.getBody();

        Map<String, Object> result = new Map<String, Object>{ 'statusCode' => statusCode, 'status' => res.getStatus() };

        if (String.isNotBlank(responseBody)) {
            try {
                result.put('body', JSON.deserializeUntyped(responseBody));
            } catch (Exception e) {
                result.put('body', responseBody);
            }
        }

        if (statusCode >= 200 && statusCode < 300) {
            return ActionOutcome.success(result);
        }

        String errorDetail = String.isNotBlank(responseBody) ? responseBody.abbreviate(500) : '(empty body)';
        return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'HTTP ' + statusCode + ' ' + res.getStatus() + ': ' + errorDetail);
    }

    // ===== CONFIGURATION =====

    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        this.config = new ConfigDTO();

        if (String.isBlank(actionConfigurationJson)) {
            throw new ValidationException('"namedCredential", "endpoint", and "method" are required in backend configuration');
        }

        try {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            this.config.namedCredential = ActionConfigUtils.getRequiredString(configMap, 'namedCredential');
            this.config.endpoint = ActionConfigUtils.getRequiredString(configMap, 'endpoint');
            this.config.method = ActionConfigUtils.getRequiredString(configMap, 'method').toUpperCase();

            if (!VALID_METHODS.contains(this.config.method)) {
                throw new ValidationException(
                    '"method" must be one of: ' + String.join(new List<String>(VALID_METHODS), ', ') + '. Got: "' + this.config.method + '"'
                );
            }

            if (!this.config.endpoint.startsWith('/')) {
                throw new ValidationException('"endpoint" must start with "/" (e.g., "/v1/cases"). Got: "' + this.config.endpoint + '"');
            }

            Map<String, Object> headersRaw = ActionConfigUtils.getOptionalMap(configMap, 'headers');
            if (!headersRaw.isEmpty()) {
                this.config.headers = new Map<String, String>();
                for (String k : headersRaw.keySet()) {
                    this.config.headers.put(k, String.valueOf(headersRaw.get(k)));
                }
            }

            Map<String, Object> staticQpRaw = ActionConfigUtils.getOptionalMap(configMap, 'staticQueryParams');
            if (!staticQpRaw.isEmpty()) {
                this.config.staticQueryParams = new Map<String, String>();
                for (String k : staticQpRaw.keySet()) {
                    this.config.staticQueryParams.put(k, String.valueOf(staticQpRaw.get(k)));
                }
            }

            this.config.timeout = ActionConfigUtils.getOptionalInteger(configMap, 'timeout', DEFAULT_TIMEOUT_MS);
            if (this.config.timeout > MAX_TIMEOUT_MS) {
                this.config.timeout = MAX_TIMEOUT_MS;
            }
        } catch (ValidationException ve) {
            throw ve;
        } catch (Exception e) {
            throw new ValidationException('Invalid configuration JSON: ' + e.getMessage());
        }
    }

    // ===== HELPERS =====

    @TestVisible
    private String resolveTemplate(String template, Map<String, Object> variables) {
        String result = template;
        for (String key : variables.keySet()) {
            Object val = variables.get(key);
            if (val != null) {
                result = result.replace('{' + key + '}', EncodingUtil.urlEncode(String.valueOf(val), 'UTF-8'));
            }
        }
        return result;
    }

    private Boolean hasUnresolvedPlaceholders(String path) {
        Integer openBrace = path.indexOf('{');
        if (openBrace == -1) {
            return false;
        }
        return path.indexOf('}', openBrace) != -1;
    }

    @TestVisible
    private String buildQueryString(Map<String, String> staticParams, Map<String, Object> runtimeParams) {
        List<String> parts = new List<String>();

        if (staticParams != null) {
            for (String k : staticParams.keySet()) {
                parts.add(EncodingUtil.urlEncode(k, 'UTF-8') + '=' + EncodingUtil.urlEncode(staticParams.get(k), 'UTF-8'));
            }
        }

        if (runtimeParams != null) {
            for (String k : runtimeParams.keySet()) {
                Object val = runtimeParams.get(k);
                if (val != null) {
                    parts.add(EncodingUtil.urlEncode(k, 'UTF-8') + '=' + EncodingUtil.urlEncode(String.valueOf(val), 'UTF-8'));
                }
            }
        }

        return String.join(parts, '&');
    }

    // ===== HTTP CLIENT ABSTRACTION (for testability) =====

    @TestVisible
    interface IHttpClient {
        HttpResponse send(HttpRequest req);
    }

    private class DefaultHttpClient implements IHttpClient {
        public HttpResponse send(HttpRequest req) {
            return new Http().send(req);
        }
    }
}
