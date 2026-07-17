# =============================================================================
# app.R — NAS Delay Dashboard (R Shiny)
#
# Reads the pre-aggregated daily_summary (and flights_clean for one histogram)
# from Neon Postgres and serves three interactive tabs. All SQL lives in
# queries.R; this file is only UI + reactivity + charts.
#
# Run locally from RStudio: open this file and click "Run App".
# =============================================================================

library(shiny)
library(DBI)
library(pool)
library(ggplot2)
library(scales)

# --- Startup (runs ONCE when the app launches) -------------------------------

# Load DB credentials. Locally they come from the project-root .Renviron;
# on shinyapps.io they'll be set as deployment environment variables instead.
# Credentials: on shinyapps.io they come from a .Renviron bundled IN this app
# folder (rsconnect ships it; R auto-reads it at startup). Locally they come
# from the project-root .Renviron. Read whichever exists.
for (envfile in c(".Renviron", "../.Renviron")) if (file.exists(envfile)) readRenviron(envfile)

source("queries.R")   # the query functions (this file's wd is the app/ folder)

# A connection POOL, not a single connection: pool validates connections on
# checkout and transparently replaces dead ones — so when Neon's free tier
# suspends the compute after idle, the next query just reopens a fresh one.
# It's also concurrency-safe. queries.R is unchanged — a pool works with
# dbGetQuery exactly like a plain connection.
con <- dbPool(
  RPostgres::Postgres(),
  host     = Sys.getenv("PGHOST"),
  dbname   = Sys.getenv("PGDATABASE"),
  user     = Sys.getenv("PGUSER"),
  password = Sys.getenv("PGPASSWORD"),
  port     = as.integer(Sys.getenv("PGPORT", "5432")),
  sslmode  = "require"
)
onStop(function() poolClose(con))   # close the whole pool when the app stops

# Query the bounds/choices needed to populate the input controls, once.
bounds   <- date_bounds(con)
airports <- airport_list(con)

# A shared ggplot theme so every chart looks consistent.
theme_dash <- theme_minimal(base_size = 14) +
  theme(plot.title = element_text(face = "bold"),
        panel.grid.minor = element_blank())

# Small helper: a titled KPI "card" for the UI (a value on top, label below).
kpi_card <- function(id, label) {
  column(3, div(
    style = "text-align:center; padding:14px; border:1px solid #e2e2e2; border-radius:10px;",
    div(style = "font-size:26px; font-weight:700;", textOutput(id)),
    div(style = "color:#777; font-size:13px;", label)
  ))
}

# --- UI: what the page looks like --------------------------------------------

ui <- fluidPage(
  titlePanel("NAS Delay Dashboard — US Flight On-Time Performance"),

  # Shared control: one date range that every tab reacts to.
  fluidRow(column(5, dateRangeInput(
    "dates", "Date range:",
    start = bounds$min_date, end = bounds$max_date,
    min   = bounds$min_date, max = bounds$max_date
  ))),

  tabsetPanel(
    # ---- Tab 1: Overview ----
    tabPanel(
      "Overview",
      br(),
      fluidRow(
        kpi_card("kpi_flights", "Total flights"),
        kpi_card("kpi_ontime",  "On-time rate"),
        kpi_card("kpi_delay",   "Avg arrival delay"),
        kpi_card("kpi_cancel",  "Cancellation rate")
      ),
      hr(),
      plotOutput("trend_plot", height = "360px")
    ),

    # ---- Tab 2: By airport ----
    tabPanel(
      "By airport",
      br(),
      fluidRow(column(4, selectInput(
        "airport", "Origin airport:", choices = airports$origin
      ))),
      fluidRow(
        kpi_card("akpi_flights", "Flights from airport"),
        kpi_card("akpi_ontime",  "On-time rate"),
        kpi_card("akpi_delay",   "Avg arrival delay"),
        kpi_card("akpi_cancel",  "Cancellation rate")
      ),
      hr(),
      fluidRow(
        column(6, plotOutput("cause_plot", height = "340px")),
        column(6, plotOutput("dist_plot",  height = "340px"))
      )
    ),

    # ---- Tab 3: Carrier comparison ----
    tabPanel(
      "Carrier comparison",
      br(),
      plotOutput("carrier_plot", height = "560px")
    )
  )
)

# --- Server: what the page does ----------------------------------------------

server <- function(input, output, session) {

  # Refresh the input controls from the DB at the start of every session, so a
  # browser refresh picks up newly-loaded months (e.g. after running the ETL)
  # without restarting the app. Runs once per session (no reactive deps).
  observe({
    b <- date_bounds(con)
    updateDateRangeInput(session, "dates",
      start = b$min_date, end = b$max_date, min = b$min_date, max = b$max_date)
    updateSelectInput(session, "airport", choices = airport_list(con)$origin)
  })

  # ===== Tab 1: Overview =====

  # One reactive query, reused by all four KPI cards. Recomputes only when
  # the date range changes; the four renderText outputs share this one result.
  ov <- reactive({
    overview_kpis(con, input$dates[1], input$dates[2])
  })

  output$kpi_flights <- renderText(format(ov()$total_flights, big.mark = ","))
  output$kpi_ontime  <- renderText(percent(ov()$on_time_rate, accuracy = 0.1))
  output$kpi_delay   <- renderText(sprintf("%.1f min", ov()$avg_arr_delay))
  output$kpi_cancel  <- renderText(percent(ov()$cancel_rate, accuracy = 0.01))

  output$trend_plot <- renderPlot({
    d <- daily_trend(con, input$dates[1], input$dates[2])
    ggplot(d, aes(flight_date, on_time_rate)) +
      geom_line(color = "#2c7fb8", linewidth = 0.8) +
      geom_point(color = "#2c7fb8", size = 1.5) +
      scale_y_continuous(labels = percent) +
      labs(title = "Daily on-time rate", x = NULL, y = "On-time rate") +
      theme_dash
  })

  # ===== Tab 2: By airport =====

  ak <- reactive({
    airport_kpis(con, input$airport, input$dates[1], input$dates[2])
  })

  output$akpi_flights <- renderText(format(ak()$total_flights, big.mark = ","))
  output$akpi_ontime  <- renderText(percent(ak()$on_time_rate, accuracy = 0.1))
  output$akpi_delay   <- renderText(sprintf("%.1f min", ak()$avg_arr_delay))
  output$akpi_cancel  <- renderText(percent(ak()$cancel_rate, accuracy = 0.01))

  output$cause_plot <- renderPlot({
    d <- cause_breakdown(con, input$airport, input$dates[1], input$dates[2])
    ggplot(d, aes(x = reorder(cause, minutes), y = minutes)) +
      geom_col(fill = "#d95f0e") +
      coord_flip() +
      scale_y_continuous(labels = label_number(scale_cut = cut_short_scale())) +
      labs(title = paste("Delay minutes by cause —", input$airport),
           x = NULL, y = "Total delay minutes") +
      theme_dash
  })

  output$dist_plot <- renderPlot({
    d <- delay_distribution(con, input$airport, input$dates[1], input$dates[2])
    ggplot(d, aes(bucket_min, n)) +
      geom_col(fill = "#2c7fb8") +
      geom_vline(xintercept = 15, linetype = "dashed", color = "grey40") +
      coord_cartesian(xlim = c(-60, 180)) +   # zoom to the meaningful range
      labs(title = paste("Arrival-delay distribution —", input$airport),
           subtitle = "Dashed line = 15-min on-time threshold",
           x = "Arrival delay (min, 15-min bins)", y = "Flights") +
      theme_dash
  })

  # ===== Tab 3: Carrier comparison =====

  output$carrier_plot <- renderPlot({
    d <- carrier_comparison(con, input$dates[1], input$dates[2])
    ggplot(d, aes(x = reorder(carrier, on_time_rate), y = on_time_rate)) +
      geom_col(fill = "#31a354") +
      coord_flip() +
      scale_y_continuous(labels = percent) +
      labs(title = "On-time rate by carrier",
           subtitle = "Carriers with 500+ flights in the selected range",
           x = NULL, y = "On-time rate") +
      theme_dash
  })
}

# --- Launch ------------------------------------------------------------------
shinyApp(ui, server)
