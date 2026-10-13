/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Agent Channels health and fixes for the Pluto Overview. Reaches the optional
 * Agent Channels package by name, so Pluto deploys without it and shows the
 * section as unavailable. The package checks Agent Channels Operate.
 */
public with sharing class PlutoChannelsController {
    private static final String OPERATIONS_CLASS = 'AgentChannelOperations';
    @TestVisible
    private static System.Callable operationsForTest;

    @AuraEnabled
    public static Map<String, Object> getChannelsHealth() {
        System.Callable operations = operations();
        if (operations == null) {
            return new Map<String, Object>{ 'available' => false };
        }
        try {
            return new Map<String, Object>{ 'available' => true, 'snapshot' => operations.call('snapshot', null), 'parked' => operations.call('parked', null) };
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    @AuraEnabled
    public static Id installChannelsSweep() {
        try {
            return (Id) required().call('installSweep', null);
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    @AuraEnabled
    public static Boolean retryChannelMessage(Id messageId) {
        try {
            return (Boolean) required().call('retry', new Map<String, Object>{ 'messageId' => messageId });
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    private static System.Callable operations() {
        if (Test.isRunningTest() && operationsForTest != null) {
            return operationsForTest;
        }
        Type operationsType = Type.forName(OPERATIONS_CLASS);
        return operationsType == null ? null : (System.Callable) operationsType.newInstance();
    }

    private static System.Callable required() {
        System.Callable operations = operations();
        if (operations == null) {
            throw new AuraHandledException('Agent Channels is not installed in this org.');
        }
        return operations;
    }

    private static AuraHandledException auraError(Exception failure) {
        AuraHandledException error = new AuraHandledException(failure.getMessage());
        error.setMessage(failure.getMessage());
        return error;
    }
}
