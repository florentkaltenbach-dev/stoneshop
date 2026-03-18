<?php
/**
 * Single product template override (custom router).
 *
 * This file intentionally routes to the theme render layer instead of using
 * the default WooCommerce single-product markup.
 *
 * @see https://woocommerce.com/document/template-structure/
 * @package WooCommerce\Templates
 * @version 1.6.4
 */

defined('ABSPATH') || exit;

get_header();

require_once get_template_directory() . '/inc/smg-render.php';

global $product;

if (!$product || !is_a($product, 'WC_Product')) {
    $product = wc_get_product(get_the_ID());
}

if ($product && is_a($product, 'WC_Product')) {
    smg_render_stone_detail($product);
}

get_footer();
