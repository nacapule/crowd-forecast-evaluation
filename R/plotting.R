# Shared figure style for the analysis notebooks.
#
# One palette and one theme across every figure in the project, so panels
# from different notebooks sit next to each other without re-reading. Series
# colours are taken in a fixed order, and no panel carries more than three of
# them; anything further goes in the adjacent table rather than a fourth line.

cfe_palette <- c("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4")
cfe_ink <- "#0b0b0b"
cfe_ink2 <- "#52514e"
cfe_muted <- "#898781"
cfe_grid <- "#e1e0d9"
cfe_surface <- "#fcfcfb"

theme_cfe <- function(base_size = 12) {
  ggplot2::theme_minimal(base_size = base_size) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = cfe_surface, color = NA),
      panel.background = ggplot2::element_rect(fill = cfe_surface, color = NA),
      panel.grid.major = ggplot2::element_line(color = cfe_grid,
                                               linewidth = 0.3),
      panel.grid.minor = ggplot2::element_blank(),
      text = ggplot2::element_text(color = cfe_ink),
      axis.text = ggplot2::element_text(color = cfe_muted, size = 9),
      axis.title = ggplot2::element_text(color = cfe_ink2, size = 10),
      strip.text = ggplot2::element_text(color = cfe_ink, face = "bold",
                                         size = 10),
      legend.position = "bottom",
      legend.text = ggplot2::element_text(color = cfe_ink2, size = 9),
      legend.title = ggplot2::element_blank(),
      plot.title = ggplot2::element_text(face = "bold", size = 13),
      plot.subtitle = ggplot2::element_text(color = cfe_ink2, size = 10)
    )
}

# Writes a figure next to the notebook and returns the plot, so a chunk can
# both save and display it.
save_fig <- function(p, name, w = 8, h = 4.5, dir = "figures") {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  ggplot2::ggsave(file.path(dir, name), p, width = w, height = h,
                  bg = cfe_surface, dpi = 200)
  p
}
