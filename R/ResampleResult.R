#' @title Container for Results of `resample()`
#'
#' @include mlr_reflections.R
#'
#' @description
#' This is the result container object returned by [resample()].
#'
#' Note that all stored objects are accessed by reference.
#' Do not modify any object without cloning it first.
#'
#' @template param_measures
#'
#' @section S3 Methods:
#' * `as.data.table(rr)`\cr
#'   [ResampleResult] -> [data.table::data.table()]\cr
#'   Returns a copy of the internal data.
#' * `c(...)`\cr
#'   ([ResampleResult], ...) -> [BenchmarkResult]\cr
#'   Combines multiple objects convertible to [BenchmarkResult] into a new [BenchmarkResult].
#'
#' @export
#' @examples
#' task = tsk("iris")
#' learner = lrn("classif.rpart")
#' resampling = rsmp("cv", folds = 3)
#' rr = resample(task, learner, resampling)
#' print(rr)
#'
#' rr$aggregate(msr("classif.acc"))
#' rr$prediction()
#' rr$prediction()$confusion
#' rr$warnings
#' rr$errors
ResampleResult = R6Class("ResampleResult",
  public = list(
    #' @field data ([data.table::data.table()])\cr
    #'   Internal data storage.
    #'   We discourage users to directly work with this field.
    data = NULL,

    #' @description
    #' Creates a new instance of this [R6][R6::R6Class] class.
    #'
    #' @param data ([data.table::data.table()])\cr
    #'   Table with data for one resampling iteration per row:
    #'   [Task], [Learner], [Resampling], iteration (`integer(1)`), and [Prediction].
    #'
    #' @param uhash (`character(1)`)\cr
    #'   Unique hash for this `ResampleResult`. If `NULL`, a new unique hash is generated.
    #'   This unique hash is primarily needed to group information in [BenchmarkResult]s.
    initialize = function(data, uhash = NULL) {
      assert_data_table(data)
      slots = mlr_reflections$rr_names
      assert_names(names(data), must.include = slots)
      self$data = setcolorder(setcolorder(data, "iteration"), slots)[]
      if (is.null(uhash)) {
        private$.uhash = UUIDgenerate()
      } else {
        private$.uhash = assert_string(uhash)
      }
    },

    #' @description
    #' Helper for print outputs.
    format = function() {
      sprintf("<%s>", class(self)[1L])
    },

    #' @description
    #' Printer.
    #' @param ... (ignored).
    print = function() {
      catf("%s of %i iterations", format(self), nrow(self$data))
      catf(str_indent("* Task:", self$task$id))
      catf(str_indent("* Learner:", self$data$learner[[1L]]$id))

      warnings = self$warnings
      catf(str_indent("* Warnings:", sprintf("%i in %i iterations", nrow(warnings), uniqueN(warnings, by = "iteration"))))

      errors = self$errors
      catf(str_indent("* Errors:", sprintf("%i in %i iterations", nrow(errors), uniqueN(errors, by = "iteration"))))
    },

    #' @description
    #' Opens the corresponding help page referenced by field `$man`.
    help = function() {
      open_help("mlr3::ResampleResult")
    },

    #' @description
    #' Combined [Prediction] of all individual resampling iterations, and all provided predict sets.
    #' Note that performance measures do not operate on this object,
    #' but instead on each prediction object separately and then combine the performance scores
    #' with the aggregate function of the respective [Measure].
    #'
    #' @param predict_sets (`character()`)\cr
    #'   Subset of `{"train", "test"}`.
    #' @return [Prediction].
    prediction = function(predict_sets = "test") {
      do.call(c, self$predictions(predict_sets = predict_sets))
    },

    #' @description
    #' List of prediction objects, sorted by resampling iteration.
    #' If multiple sets are given, these are combined to a single one for each iteration.
    #'
    #' @param predict_sets (`character()`)\cr
    #'   Subset of `{"train", "test"}`.
    #' @return List of [Prediction] objects, one per element in `predict_sets`.
    predictions = function(predict_sets = "test") {
      map(self$data$prediction, function(li) {
        do.call(c, li[predict_sets])
      })
    },

    #' @description
    #' Returns a table with one row for each resampling iteration, including all involved objects:
    #' [Task], [Learner], [Resampling], iteration number (`integer(1)`), and [Prediction].
    #' Additionally, a column with the individual (per resampling iteration) performance is added for each [Measure] in `measures`,
    #' named with the id of the respective measure id.
    #' If `measures` is `NULL`, `measures` defaults to the return value of [default_measures()].
    #'
    #' @param ids (`logical(1)`)\cr
    #'   If `ids` is `TRUE`, extra columns with the ids of objects (`"task_id"`, `"learner_id"`, `"resampling_id"`) are added to the returned table.
    #'   These allow to subset more conveniently.
    #'
    #' @return [data.table::data.table()].
    score = function(measures = NULL, ids = TRUE) {
      measures = as_measures(measures, task_type = self$task$task_type)
      assert_measures(measures, task = self$task, learner = self$learners[[1L]])
      assert_flag(ids)
      tab = copy(self$data)

      for (m in measures) {
        set(tab, j = m$id, value = measure_score_data(m, self$data))
      }

      if (ids) {
        tab[, c("task_id", "learner_id", "resampling_id") := list(ids(task), ids(learner), ids(resampling))]
        setcolorder(tab, c("task", "task_id", "learner", "learner_id", "resampling", "resampling_id", "iteration", "prediction"))[]
      }

      tab[]
    },

    #' @description
    #' Calculates and aggregates performance values for all provided measures, according to the respective aggregation function in [Measure].
    #' If `measures` is `NULL`, `measures` defaults to the return value of [default_measures()].
    #'
    #' @return Named `numeric()`.
    aggregate = function(measures = NULL) {
      measures = as_measures(measures, task_type = self$task$task_type)
      assert_measures(measures, task = self$task, learner = self$learners[[1L]])
      set_names(map_dbl(measures, function(m) m$aggregate(self)), ids(measures))
    },

    #' @description
    #' Subsets the [ResampleResult], reducing it to only keep the iterations specified in `iters`.
    #'
    #' @param iters (`integer()`)\cr
    #'   Resampling iterations to keep.
    #'
    #' @return
    #' Returns the object itself, but modified **by reference**.
    #' You need to explicitly `$clone()` the object beforehand if you want to keeps
    #' the object in its previous state.
    filter = function(iters) {
      resampling = self$resampling
      iters = assert_integerish(iters, min.len = 1L, lower = 1L, upper = resampling$iters, any.missing = FALSE, coerce = TRUE)

      self$data = self$data[list(unique(iters)), on = "iteration"]
      invisible(self)
    }
  ),

  active = list(
    #' @field task ([Task])\cr
    #' The task [resample()] operated on.
    task = function(rhs) {
      assert_ro_binding(rhs)
      self$data$task[[1L]]
    },

    #' @field learners (list of [Learner])\cr
    #' List of trained learners, sorted by resampling iteration.
    learners = function(rhs) {
      assert_ro_binding(rhs)
      self$data$learner
    },

    #' @field resampling ([Resampling])\cr
    #' Instantiated [Resampling] object which stores the splits into training and test.
    resampling = function(rhs) {
      assert_ro_binding(rhs)
      self$data$resampling[[1L]]
    },

    #' @field uhash (`character(1)`)\cr
    #' Unique hash for this object.
    uhash = function(rhs) {
      if (missing(rhs)) {
        return(private$.uhash)
      }
      private$.uhash = assert_string(rhs)
    },

    #' @field warnings ([data.table::data.table()])\cr
    #' A table with all warning messages.
    #' Column names are `"iteration"` and `"msg"`.
    #' Note that there can be multiple rows per resampling iteration if multiple warnings have been recorded.
    warnings = function(rhs) {
      assert_ro_binding(rhs)
      extract = function(learner) list(msg = learner$warnings)
      rbindlist(map(self$data$learner, extract), idcol = "iteration", use.names = TRUE)
    },

    #' @field errors ([data.table::data.table()])\cr
    #' A table with all error messages.
    #' Column names are `"iteration"` and `"msg"`.
    #' Note that there can be multiple rows per resampling iteration if multiple errors have been recorded.
    errors = function(rhs) {
      assert_ro_binding(rhs)
      extract = function(learner) list(msg = learner$errors)
      rbindlist(map(self$data$learner, extract), idcol = "iteration", use.names = TRUE)
    }
  ),

  private = list(
    .uhash = NULL,

    deep_clone = function(name, value) {
      if (name == "data") copy(value) else value
    }
  )
)

#' @export
as.data.table.ResampleResult = function(x, ...) {
  copy(x$data)
}

#' @export
c.ResampleResult = function(...) {
  do.call(c, lapply(list(...), as_benchmark_result))
}

#' @rdname as_benchmark_result
#' @export
as_benchmark_result.ResampleResult = function(x, ...) {
  BenchmarkResult$new(cbind(x$data, data.table(uhash = x$uhash)))
}
