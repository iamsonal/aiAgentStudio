/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

const LOG_LEVEL = {
    DEBUG: 'DEBUG',
    INFO: 'INFO',
    WARN: 'WARN',
    ERROR: 'ERROR'
};


const logger = {
    
    debug(context, message) {
        this._log(LOG_LEVEL.DEBUG, context, message);
    },

    
    info(context, message) {
        this._log(LOG_LEVEL.INFO, context, message);
    },

    
    warn(context, message) {
        this._log(LOG_LEVEL.WARN, context, message);
    },

    
    error(context, error) {
        this._log(LOG_LEVEL.ERROR, context, error);

        
        
    },

    
    _log(level, context, message) {
        
        const formattedMessage = `[${level}] ${context}: ${this._formatMessage(message)}`;

        switch (level) {
            case LOG_LEVEL.DEBUG:
                
                if (!this._isProduction()) {
                    console.debug(formattedMessage);
                }
                break;
            case LOG_LEVEL.INFO:
                console.info(formattedMessage);
                break;
            case LOG_LEVEL.WARN:
                console.warn(formattedMessage);
                break;
            case LOG_LEVEL.ERROR:
                console.error(formattedMessage);
                break;
            default:
                console.log(formattedMessage);
        }
    },

    
    _formatMessage(message) {
        if (message instanceof Error) {
            return `${message.name}: ${message.message}\nStack: ${message.stack || 'No stack trace available'}`;
        } else if (typeof message === 'object') {
            try {
                return JSON.stringify(message);
            } catch (e) {
                return '[Object that cannot be stringified]';
            }
        }
        return String(message);
    },

    
    _isProduction() {
        
        
        return false;
    }
};


export { logger, LOG_LEVEL };