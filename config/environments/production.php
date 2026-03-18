<?php
/**
 * Production environment configuration
 */

use Roots\WPConfig\Config;

Config::define('WP_DEBUG', false);
Config::define('WP_DEBUG_LOG', false);
Config::define('WP_DEBUG_DISPLAY', false);

// Force HTTPS
Config::define('FORCE_SSL_ADMIN', true);
$_SERVER['HTTPS'] = 'on';
