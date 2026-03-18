<?php
/**
 * Main Template File
 *
 * @package SteineMitGeschichte
 */

get_header();
?>

<div class="content-area">
    <?php smg_breadcrumbs(); ?>

    <?php if (have_posts()) : ?>
        <div class="posts-list">
            <?php while (have_posts()) : the_post(); ?>
                <article id="post-<?php the_ID(); ?>" <?php post_class(); ?>>
                    <h2 class="entry-title">
                        <a href="<?php the_permalink(); ?>"><?php the_title(); ?></a>
                    </h2>
                    <div class="entry-summary">
                        <?php the_excerpt(); ?>
                    </div>
                </article>
            <?php endwhile; ?>
        </div>

        <?php the_posts_pagination([
            'prev_text' => __('Previous', 'steine-mit-geschichte'),
            'next_text' => __('Next', 'steine-mit-geschichte'),
        ]); ?>

    <?php else : ?>
        <p><?php esc_html_e('No content found.', 'steine-mit-geschichte'); ?></p>
    <?php endif; ?>
</div>

<?php
get_footer();
