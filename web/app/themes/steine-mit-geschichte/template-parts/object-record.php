<?php
/**
 * Object Record Component
 *
 * The smallest reusable unit.
 * Used across collections, related objects, and references.
 *
 * Includes:
 * - Object image (dominant)
 * - Object name or designation
 * - Minimal metadata (place, material, period)
 *
 * Rules:
 * - No overlays or badges
 * - No hover gimmicks
 * - Entire record is a single focusable element
 *
 * @package SteineMitGeschichte
 */

defined('ABSPATH') || exit;

global $product;

// Ensure $product is a proper WC_Product object
if (!$product || !is_a($product, 'WC_Product')) {
    $product = wc_get_product(get_the_ID());
}

if (!$product) {
    return;
}

$product_id = $product->get_id();
$permalink  = get_permalink($product_id);
$title      = get_the_title($product_id);
?>

<article class="object-record">
    <a href="<?php echo esc_url($permalink); ?>" class="object-record__link" aria-label="<?php echo esc_attr($title); ?>">
        <figure class="object-record__image">
            <?php if (has_post_thumbnail($product_id)) : ?>
                <?php echo get_the_post_thumbnail($product_id, 'object-medium', ['loading' => 'lazy']); ?>
            <?php else : ?>
                <div class="object-record__placeholder" aria-hidden="true"></div>
            <?php endif; ?>
        </figure>

        <div class="object-record__details">
            <h3 class="object-record__title"><?php echo esc_html($title); ?></h3>

            <dl class="object-record__metadata">
                <?php
                // Place (location/origin attribute)
                $place = $product->get_attribute('pa_location');
                if ($place) : ?>
                    <div class="object-record__meta-item">
                        <dt class="screen-reader-text"><?php esc_html_e('Place', 'steine-mit-geschichte'); ?></dt>
                        <dd><?php echo esc_html($place); ?></dd>
                    </div>
                <?php endif; ?>

                <?php
                // Material attribute
                $material = $product->get_attribute('pa_material');
                if ($material) : ?>
                    <div class="object-record__meta-item">
                        <dt class="screen-reader-text"><?php esc_html_e('Material', 'steine-mit-geschichte'); ?></dt>
                        <dd><?php echo esc_html($material); ?></dd>
                    </div>
                <?php endif; ?>

                <?php
                // Period attribute
                $period = $product->get_attribute('pa_period');
                if ($period) : ?>
                    <div class="object-record__meta-item">
                        <dt class="screen-reader-text"><?php esc_html_e('Period', 'steine-mit-geschichte'); ?></dt>
                        <dd><?php echo esc_html($period); ?></dd>
                    </div>
                <?php endif; ?>
            </dl>
        </div>
    </a>
</article>
