<?php
/**
 * Steine mit Geschichte — Render Layer (Control Surface)
 *
 * Centralizes markup for:
 * - Collections Index (Shop)
 * - Collection page (product category)
 * - Stone detail (single product)
 *
 * Variants:
 * - v1: Soft Commerce (Acquire section on stone detail)
 * - v2: More Physical Object Presence (bigger objects, fewer per page; used via CSS/classes)
 * - v3: Stronger Curatorial Voice (intro prominence/placement)
 */

defined('ABSPATH') || exit;

/**
 * Utility: ensure Woo product object is available.
 */
function smg_get_current_product(): ?WC_Product {
    global $product;
    if ($product && is_a($product, 'WC_Product')) {
        return $product;
    }
    $p = wc_get_product(get_the_ID());
    if ($p && is_a($p, 'WC_Product')) {
        $product = $p;
        return $p;
    }
    return null;
}

/**
 * Render: Collections Index (Shop page)
 * Lists collections (product categories), not products.
 */
function smg_render_collections_index(): void {
    $default_category_id = (int) get_option('default_product_cat', 0);
    $top_level_categories = get_terms([
        'taxonomy'   => 'product_cat',
        'orderby'    => 'name',
        'order'      => 'ASC',
        'hide_empty' => false,
        'parent'     => 0,
        'exclude'    => [$default_category_id],
    ]);
    ?>
    <div class="smg-page collections-index <?php echo smg_variant_class(); ?>">
        <div class="container-mid">
            <?php smg_breadcrumbs(); ?>
        </div>

        <header class="collections-header container-mid">
            <h1 class="collections-title"><?php esc_html_e('Sammlungen', 'steine-mit-geschichte'); ?></h1>
            <p class="collections-subtitle">
                <?php esc_html_e('Kuratierte Gruppen von Steinen, jede mit eigener Geschichte und eigenem Charakter.', 'steine-mit-geschichte'); ?>
            </p>
        </header>

        <?php if (!empty($top_level_categories) && !is_wp_error($top_level_categories)) : ?>
            <section class="collections-grid container-wide" aria-label="<?php esc_attr_e('Alle Sammlungen', 'steine-mit-geschichte'); ?>">
                <ul class="collections-list">
                    <?php foreach ($top_level_categories as $category) : ?>
                        <li class="collections-list__item">
                            <?php smg_render_collection_card($category); ?>

                            <?php
                            $child_categories = get_terms([
                                'taxonomy'   => 'product_cat',
                                'orderby'    => 'name',
                                'order'      => 'ASC',
                                'hide_empty' => false,
                                'parent'     => (int) $category->term_id,
                                'exclude'    => [$default_category_id],
                            ]);
                            ?>
                            <?php if (!empty($child_categories) && !is_wp_error($child_categories)) : ?>
                                <ul class="collection-card__children" aria-label="<?php echo esc_attr(sprintf(__('Unterkategorien von %s', 'steine-mit-geschichte'), $category->name)); ?>">
                                    <?php foreach ($child_categories as $child_category) : ?>
                                        <?php
                                        $child_count = isset($child_category->count) ? (int) $child_category->count : 0;
                                        $child_url = smg_url_with_variant(get_term_link($child_category));
                                        ?>
                                        <li class="collection-card__children-item">
                                            <a class="collection-card__children-link" href="<?php echo esc_url($child_url); ?>">
                                                <span class="collection-card__children-name"><?php echo esc_html($child_category->name); ?></span>
                                                <span class="collection-card__children-count">
                                                    <?php
                                                    printf(
                                                        /* translators: %d = number of stones in collection */
                                                        esc_html(_n('%d Stein', '%d Steine', $child_count, 'steine-mit-geschichte')),
                                                        $child_count
                                                    );
                                                    ?>
                                                </span>
                                            </a>
                                        </li>
                                    <?php endforeach; ?>
                                </ul>
                            <?php endif; ?>
                        </li>
                    <?php endforeach; ?>
                </ul>
            </section>
        <?php else : ?>
            <p class="collections-empty container-mid">
                <?php esc_html_e('Keine Sammlungen verfügbar.', 'steine-mit-geschichte'); ?>
            </p>
        <?php endif; ?>
    </div>
    <?php
}

/**
 * Render: Tags Index (Shop page)
 * Lists product tags as a card grid.
 */
function smg_render_tags_index(): void {
    $tags = get_terms([
        'taxonomy'   => 'product_tag',
        'orderby'    => 'name',
        'order'      => 'ASC',
        'hide_empty' => true,
    ]);
    ?>
    <div class="smg-page tags-index <?php echo smg_variant_class(); ?>">
        <div class="container-mid">
            <?php smg_breadcrumbs(); ?>
        </div>

        <header class="tags-header container-mid">
            <h1 class="tags-title"><?php esc_html_e('Themen', 'steine-mit-geschichte'); ?></h1>
            <p class="tags-subtitle">
                <?php esc_html_e('Steine nach Thema erkunden', 'steine-mit-geschichte'); ?>
            </p>
        </header>

        <?php if (!empty($tags) && !is_wp_error($tags)) : ?>
            <section class="tags-grid container-wide" aria-label="<?php esc_attr_e('Alle Themen', 'steine-mit-geschichte'); ?>">
                <ul class="tags-list">
                    <?php foreach ($tags as $tag) : ?>
                        <li class="tags-list__item">
                            <?php smg_render_tag_card($tag); ?>
                        </li>
                    <?php endforeach; ?>
                </ul>
            </section>
        <?php else : ?>
            <p class="tags-empty container-mid">
                <?php esc_html_e('Keine Themen verfügbar.', 'steine-mit-geschichte'); ?>
            </p>
        <?php endif; ?>
    </div>
    <?php
}

/**
 * Render: a tag card on /shop (tags index)
 */
function smg_render_tag_card(WP_Term $term): void {
    $url   = smg_url_with_variant(get_term_link($term));
    $count = isset($term->count) ? (int) $term->count : 0;

    $image_id = smg_get_tag_image_id((int) $term->term_id);
    $img_html = $image_id ? wp_get_attachment_image($image_id, 'object-medium') : '';

    $desc = trim(wp_strip_all_tags($term->description ?? ''));
    if (mb_strlen($desc) > 180) {
        $desc = mb_substr($desc, 0, 180) . '…';
    }
    ?>
    <a class="tag-card" href="<?php echo esc_url($url); ?>">
        <div class="tag-card__image" aria-hidden="true">
            <?php if ($img_html) : ?>
                <?php echo $img_html; ?>
            <?php else : ?>
                <div class="tag-card__placeholder"></div>
            <?php endif; ?>
        </div>

        <div class="tag-card__body">
            <h2 class="tag-card__title"><?php echo esc_html($term->name); ?></h2>

            <p class="tag-card__meta">
                <?php
                printf(
                    /* translators: %d = number of stones with this tag */
                    esc_html(_n('%d Stein', '%d Steine', $count, 'steine-mit-geschichte')),
                    $count
                );
                ?>
            </p>

            <?php if (!empty($desc)) : ?>
                <p class="tag-card__desc"><?php echo esc_html($desc); ?></p>
            <?php endif; ?>
        </div>
    </a>
    <?php
}

/**
 * Render: a single Tag archive page at /thema/{slug}/
 */
function smg_render_tag_archive(): void {
    $term = get_queried_object();
    $has_intro = ($term instanceof WP_Term) && !empty($term->description);
    ?>
    <div class="smg-page tag-archive <?php echo smg_variant_class(); ?>">
        <div class="container-mid">
            <?php smg_breadcrumbs(); ?>
        </div>

        <header class="collection-header container-mid">
            <?php if ($term instanceof WP_Term) : ?>
                <h1 class="collection-title"><?php echo esc_html($term->name); ?></h1>

                <?php if ($has_intro) : ?>
                    <div class="collection-intro">
                        <?php echo wp_kses_post(wpautop($term->description)); ?>
                    </div>
                <?php endif; ?>
            <?php else : ?>
                <h1 class="collection-title"><?php woocommerce_page_title(); ?></h1>
            <?php endif; ?>
        </header>

        <?php if (woocommerce_product_loop()) : ?>
            <section class="object-field container-wide" aria-label="<?php esc_attr_e('Objekte zu diesem Thema', 'steine-mit-geschichte'); ?>">
                <?php woocommerce_product_loop_start(); ?>

                <?php while (have_posts()) : the_post(); ?>
                    <?php smg_render_object_record(); ?>
                <?php endwhile; ?>

                <?php woocommerce_product_loop_end(); ?>
            </section>

            <nav class="collection-pagination container-wide" aria-label="<?php esc_attr_e('Seitennavigation', 'steine-mit-geschichte'); ?>">
                <?php woocommerce_pagination(); ?>
            </nav>

            <?php
            $paged       = get_query_var('paged') ? (int) get_query_var('paged') : 1;
            $total_pages = (int) wc_get_loop_prop('total_pages');
            if ($total_pages > 0 && $paged >= $total_pages) : ?>
                <p class="collection-end" aria-live="polite">
                    <?php esc_html_e('Ende der Sammlung', 'steine-mit-geschichte'); ?>
                </p>
            <?php endif; ?>

        <?php else : ?>
            <p class="collection-empty container-mid"><?php esc_html_e('Keine Objekte zu diesem Thema.', 'steine-mit-geschichte'); ?></p>
        <?php endif; ?>

    </div>
    <?php
}

/**
 * Render: a single Collection (product category archive)
 */
function smg_render_collection_page(): void {
    $term = is_product_category() ? get_queried_object() : null;
    $has_intro = ($term instanceof WP_Term) && !empty($term->description);

    $emphasize_intro = smg_is_variant('v3') && $has_intro;
    ?>
    <div class="smg-page collection-page <?php echo smg_variant_class(); ?>">
        <div class="container-mid">
            <?php smg_breadcrumbs(); ?>
        </div>

        <?php if ($emphasize_intro) : ?>
            <div class="collection-curatorial container-mid">
                <div class="collection-curatorial__intro">
                    <?php echo wp_kses_post(wpautop($term->description)); ?>
                </div>
            </div>
        <?php endif; ?>

        <header class="collection-header container-mid">
            <?php if ($term instanceof WP_Term) : ?>
                <h1 class="collection-title"><?php echo esc_html($term->name); ?></h1>

                <?php if ($has_intro && !$emphasize_intro) : ?>
                    <div class="collection-intro">
                        <?php echo wp_kses_post(wpautop($term->description)); ?>
                    </div>
                <?php endif; ?>
            <?php else : ?>
                <h1 class="collection-title"><?php woocommerce_page_title(); ?></h1>
            <?php endif; ?>
        </header>

        <?php if (woocommerce_product_loop()) : ?>
            <section class="object-field container-wide" aria-label="<?php esc_attr_e('Objekte in dieser Sammlung', 'steine-mit-geschichte'); ?>">
                <?php woocommerce_product_loop_start(); ?>

                <?php while (have_posts()) : the_post(); ?>
                    <?php smg_render_object_record(); ?>
                <?php endwhile; ?>

                <?php woocommerce_product_loop_end(); ?>
            </section>

            <nav class="collection-pagination container-wide" aria-label="<?php esc_attr_e('Seitennavigation', 'steine-mit-geschichte'); ?>">
                <?php woocommerce_pagination(); ?>
            </nav>

            <?php
            $paged       = get_query_var('paged') ? (int) get_query_var('paged') : 1;
            $total_pages = (int) wc_get_loop_prop('total_pages');
            if ($total_pages > 0 && $paged >= $total_pages) : ?>
                <p class="collection-end" aria-live="polite">
                    <?php esc_html_e('Ende der Sammlung', 'steine-mit-geschichte'); ?>
                </p>
            <?php endif; ?>

        <?php else : ?>
            <p class="collection-empty container-mid"><?php esc_html_e('Keine Objekte in dieser Sammlung.', 'steine-mit-geschichte'); ?></p>
        <?php endif; ?>

    </div>
    <?php
}

/**
 * Render: a collection card on /shop (collections index)
 */
function smg_render_collection_card(WP_Term $term): void {
    $url   = smg_url_with_variant(get_term_link($term));
    $count = isset($term->count) ? (int) $term->count : 0;

    // Category thumbnail (with product fallback)
    $image_id = smg_get_collection_image_id((int) $term->term_id);
    $img_html = $image_id ? wp_get_attachment_image($image_id, 'object-medium') : '';

    // Optional: short excerpt from description (kept calm)
    $desc = trim(wp_strip_all_tags($term->description ?? ''));
    if (mb_strlen($desc) > 180) {
        $desc = mb_substr($desc, 0, 180) . '…';
    }
    ?>
    <a class="collection-card" href="<?php echo esc_url($url); ?>">
        <div class="collection-card__image" aria-hidden="true">
            <?php if ($img_html) : ?>
                <?php echo $img_html; ?>
            <?php else : ?>
                <div class="collection-card__placeholder"></div>
            <?php endif; ?>
        </div>

        <div class="collection-card__body">
            <h2 class="collection-card__title"><?php echo esc_html($term->name); ?></h2>

            <p class="collection-card__meta">
                <?php
                printf(
                    /* translators: %d = number of stones in collection */
                    esc_html(_n('%d Stein', '%d Steine', $count, 'steine-mit-geschichte')),
                    $count
                );
                ?>
            </p>

            <?php if (!empty($desc)) : ?>
                <p class="collection-card__desc"><?php echo esc_html($desc); ?></p>
            <?php endif; ?>
        </div>
    </a>
    <?php
}

/**
 * Render: Object record in a product loop.
 * Image + name + minimal metadata (place, material, period).
 * No price, no add-to-cart here (archive mode).
 */
function smg_render_object_record(): void {
    $p = smg_get_current_product();
    if (!$p) {
        return;
    }

    $place    = trim((string) $p->get_attribute('pa_location'));
    $material = trim((string) $p->get_attribute('pa_material'));
    $period   = trim((string) $p->get_attribute('pa_period'));

    $meta_parts = array_values(array_filter([$place, $material, $period]));
    ?>
    <li <?php wc_product_class('smg-object-record', $p); ?>>
        <a class="smg-object-record__link" href="<?php echo esc_url(get_permalink($p->get_id())); ?>">
            <div class="smg-object-record__image">
                <?php
                if (has_post_thumbnail($p->get_id())) {
                    echo get_the_post_thumbnail($p->get_id(), 'object-medium');
                }
                ?>
            </div>

            <div class="smg-object-record__body">
                <h3 class="smg-object-record__title"><?php echo esc_html(get_the_title($p->get_id())); ?></h3>

                <?php if (!empty($meta_parts)) : ?>
                    <p class="smg-object-record__meta">
                        <?php echo esc_html(implode(' · ', $meta_parts)); ?>
                    </p>
                <?php endif; ?>

                <?php
                $tags = get_the_terms($p->get_id(), 'product_tag');
                if (!empty($tags) && !is_wp_error($tags)) :
                    $tag_names = array_map(function ($t) { return $t->name; }, $tags);
                ?>
                    <p class="smg-object-record__tags">
                        <?php echo esc_html(implode(', ', $tag_names)); ?>
                    </p>
                <?php endif; ?>
            </div>
        </a>
    </li>
    <?php
}

/**
 * Render: Stone detail page
 */
function smg_render_stone_detail(WC_Product $product): void {
    $collection = smg_get_primary_collection_term($product->get_id());

    $weight_raw = trim((string) $product->get_weight());
    $weight = $weight_raw !== '' ? wc_format_localized_decimal($weight_raw) : '';
    $weight_unit = (string) get_option('woocommerce_weight_unit', 'kg');

    $length_raw = trim((string) $product->get_length());
    $width_raw  = trim((string) $product->get_width());
    $height_raw = trim((string) $product->get_height());
    $dimension_unit = (string) get_option('woocommerce_dimension_unit', 'cm');

    $dimension_parts = [];
    if ($length_raw !== '') {
        $dimension_parts[] = 'L ' . wc_format_localized_decimal($length_raw);
    }
    if ($width_raw !== '') {
        $dimension_parts[] = 'B ' . wc_format_localized_decimal($width_raw);
    }
    if ($height_raw !== '') {
        $dimension_parts[] = 'H ' . wc_format_localized_decimal($height_raw);
    }
    ?>
    <div class="smg-page stone-detail <?php echo smg_variant_class(); ?>">
        <div class="container-mid">
            <?php smg_breadcrumbs(); ?>
        </div>

        <article class="stone-detail__main container-wide">
            <figure class="stone-detail__image">
                <?php
                // WooCommerce gallery scripts initialize against this template markup.
                $previous_product = $GLOBALS['product'] ?? null;
                $GLOBALS['product'] = $product;

                wc_get_template('single-product/product-image.php');

                if (null !== $previous_product) {
                    $GLOBALS['product'] = $previous_product;
                } else {
                    unset($GLOBALS['product']);
                }
                ?>
            </figure>

            <div class="stone-detail__content">
                <header class="stone-detail__header">
                    <h1 class="stone-detail__title"><?php echo esc_html(get_the_title($product->get_id())); ?></h1>
                </header>

                <dl class="stone-detail__facts">
                    <?php
                    $place = trim((string) $product->get_attribute('pa_location'));
                    if ($place) : ?>
                        <div class="stone-detail__fact">
                            <dt><?php esc_html_e('Fundort', 'steine-mit-geschichte'); ?></dt>
                            <dd><?php echo esc_html($place); ?></dd>
                        </div>
                    <?php endif; ?>

                    <?php
                    $material = trim((string) $product->get_attribute('pa_material'));
                    if ($material) : ?>
                        <div class="stone-detail__fact">
                            <dt><?php esc_html_e('Material', 'steine-mit-geschichte'); ?></dt>
                            <dd><?php echo esc_html($material); ?></dd>
                        </div>
                    <?php endif; ?>

                    <?php
                    $period = trim((string) $product->get_attribute('pa_period'));
                    if ($period) : ?>
                        <div class="stone-detail__fact">
                            <dt><?php esc_html_e('Epoche', 'steine-mit-geschichte'); ?></dt>
                            <dd><?php echo esc_html($period); ?></dd>
                        </div>
                    <?php endif; ?>

                    <?php if ($weight !== '') : ?>
                        <div class="stone-detail__fact">
                            <dt><?php esc_html_e('Gewicht', 'steine-mit-geschichte'); ?></dt>
                            <dd>
                                <?php
                                echo esc_html(
                                    trim($weight . ' ' . $weight_unit)
                                );
                                ?>
                            </dd>
                        </div>
                    <?php endif; ?>

                    <?php if (!empty($dimension_parts)) : ?>
                        <div class="stone-detail__fact">
                            <dt><?php esc_html_e('Abmessungen', 'steine-mit-geschichte'); ?></dt>
                            <dd>
                                <?php
                                echo esc_html(
                                    implode(', ', $dimension_parts) . ' ' . $dimension_unit
                                );
                                ?>
                            </dd>
                        </div>
                    <?php endif; ?>

                    <?php
                    $product_tags = get_the_terms($product->get_id(), 'product_tag');
                    if (!empty($product_tags) && !is_wp_error($product_tags)) : ?>
                        <div class="stone-detail__fact">
                            <dt><?php esc_html_e('Themen', 'steine-mit-geschichte'); ?></dt>
                            <dd>
                                <?php
                                $tag_links = [];
                                foreach ($product_tags as $ptag) {
                                    $tag_links[] = '<a href="' . esc_url(get_term_link($ptag)) . '">' . esc_html($ptag->name) . '</a>';
                                }
                                echo wp_kses_post(implode(', ', $tag_links));
                                ?>
                            </dd>
                        </div>
                    <?php endif; ?>
                </dl>

                <?php if ($product->get_description()) : ?>
                    <div class="stone-detail__description">
                        <?php echo wp_kses_post($product->get_description()); ?>
                    </div>
                <?php endif; ?>

                <?php if ($product->is_purchasable()) : ?>
                    <aside class="stone-detail__acquire">
                        <h2 class="stone-detail__acquire-title"><?php esc_html_e('Erwerben', 'steine-mit-geschichte'); ?></h2>

                        <div class="stone-detail__acquire-content">
                            <?php
                            $price = (float) $product->get_price();
                            if (!empty($price) && $price > 0) : ?>
                                <p class="stone-detail__acquire-price">
                                    <?php echo wp_kses_post($product->get_price_html()); ?>
                                </p>
                            <?php else : ?>
                                <p class="stone-detail__acquire-price stone-detail__acquire-price--request">
                                    <?php esc_html_e('Preis auf Anfrage', 'steine-mit-geschichte'); ?>
                                </p>
                            <?php endif; ?>

                            <?php if ($product->is_in_stock()) : ?>
                                <form class="stone-detail__acquire-form"
                                      action="<?php echo esc_url(apply_filters('woocommerce_add_to_cart_form_action', $product->get_permalink())); ?>"
                                      method="post"
                                      enctype="multipart/form-data">
                                    <input type="hidden" name="quantity" value="1" />
                                    <button type="submit"
                                            name="add-to-cart"
                                            value="<?php echo esc_attr($product->get_id()); ?>"
                                            class="stone-detail__acquire-button">
                                        <?php esc_html_e('In den Warenkorb', 'steine-mit-geschichte'); ?>
                                    </button>
                                </form>
                            <?php else : ?>
                                <p class="stone-detail__acquire-unavailable">
                                    <?php esc_html_e('Derzeit nicht verfügbar', 'steine-mit-geschichte'); ?>
                                </p>
                            <?php endif; ?>
                        </div>
                    </aside>
                <?php endif; ?>
            </div>
        </article>

        <?php
        // Related stones within same tag (quiet, contextual)
        $primary_tag = smg_get_primary_tag($product->get_id());
        if ($primary_tag instanceof WP_Term) :
            $related_args = [
                'post_type'      => 'product',
                'posts_per_page' => smg_is_variant('v2') ? 3 : 4,
                'post__not_in'   => [$product->get_id()],
                'tax_query'      => [
                    [
                        'taxonomy' => 'product_tag',
                        'field'    => 'term_id',
                        'terms'    => $primary_tag->term_id,
                    ],
                ],
            ];
            $related = new WP_Query($related_args);

            if ($related->have_posts()) : ?>
                <aside class="stone-detail__related container-wide" aria-labelledby="related-heading">
                    <h2 id="related-heading" class="stone-detail__related-title">
                        <?php esc_html_e('Verwandte Steine zu diesem Thema', 'steine-mit-geschichte'); ?>
                    </h2>

                    <div class="object-field object-field--compact">
                        <ul class="products">
                            <?php while ($related->have_posts()) : $related->the_post(); ?>
                                <?php smg_render_object_record(); ?>
                            <?php endwhile; ?>
                        </ul>
                    </div>
                </aside>
                <?php wp_reset_postdata(); ?>
            <?php endif;
        endif; ?>
    </div>
    <?php
}
