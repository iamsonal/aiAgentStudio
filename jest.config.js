const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    moduleNameMapper: {
        ...jestConfig.moduleNameMapper,
        // Jest mocks (lwc-recipes pattern; mocks live in test/jest-mocks)
        '^@salesforce/apex$': '<rootDir>/test/jest-mocks/apex',
        '^@salesforce/schema$': '<rootDir>/test/jest-mocks/schema',
        '^lightning/navigation$': '<rootDir>/test/jest-mocks/lightning/navigation',
        '^lightning/platformShowToastEvent$': '<rootDir>/test/jest-mocks/lightning/platformShowToastEvent',
        '^lightning/uiListsApi$': '<rootDir>/test/jest-mocks/lightning/uiListsApi',
        '^lightning/uiLayoutApi$': '<rootDir>/test/jest-mocks/lightning/uiLayoutApi',
        '^lightning/uiRecordApi$': '<rootDir>/test/jest-mocks/lightning/uiRecordApi',
        '^lightning/messageService$': '<rootDir>/test/jest-mocks/lightning/messageService',
        '^lightning/actions$': '<rootDir>/test/jest-mocks/lightning/actions',
        '^lightning/illustration$': '<rootDir>/test/jest-mocks/lightning/illustration',
        '^lightning/modal$': '<rootDir>/test/jest-mocks/lightning/modal',
        '^lightning/refresh$': '<rootDir>/test/jest-mocks/lightning/refresh',
        '^lightning/logger$': '<rootDir>/test/jest-mocks/lightning/logger'
    },
    testTimeout: 10000
};
