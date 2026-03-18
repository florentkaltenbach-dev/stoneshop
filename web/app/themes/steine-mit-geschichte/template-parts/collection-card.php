<?php
/**
 * Collection Card Component
 *
 * Displays a single collection (product category) as a card.
 * Used on the Collections Index page.
 *
 * Expected variable: $category (WP_Term object)
 *
 * @package SteineMitGeschichte
 */

defined('ABSPATH') || exit;

if (!isset($category) || !$category instanceof WP_Term) {
    return;
}

$thumbnail_id = get_term_meta($category->term_id, 'thumbnail_id', true);
$count = $category->count;
?>

<article class="collection-card">
    <a href="<?php echo esc_url(get_term_link($category)); ?>" class="collection-card__link">
        <figure class="collection-card__image">
            <?php if ($thumbnail_id) : ?>
                <?php echo wp_get_attachment_image($thumbnail_id, 'object-medium', false, ['loading' => 'lazy']); ?>
            <?php else : ?>
                <div class="collection-card__placeholder" aria-hidden="true"></div>
            <?php endif; ?>
        </figure>

        <div class="collection-card__content">
            <h2 class="collection-card__title"><?php echo esc_html($category->name); ?></h2>

            <?php if ($category->description) : ?>
                <p class="collection-card__description"><?php echo esc_html(wp_trim_words($category->description, 20, '...')); ?></p>
            <?php endif; ?>

            <p class="collection-card__count">
                <?php
                printf(
                    /* translators: %d: number of objects */
                    _n('%d object', '%d objects', $count, 'steine-mit-geschichte'),
                    $count
                );
                ?>
            </p>
        </div>
    </a>
</article>
