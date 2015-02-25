module.exports = (grunt) ->
    'use strict'

    fs = require 'fs'

    webdriver = require 'selenium-webdriver'
    remote = require 'selenium-webdriver/remote'

    grunt.registerMultiTask 'webdriver_jasmine_runner', 'Runs a jasmine test with webdriver.', ->
        options = @options
            seleniumJar: __dirname + '/lib/selenium-server-standalone-2.44.0.jar'
            seleniumServerArgs: []
            seleniumServerJvmArgs: []
            browser: 'chrome'
            testServer: 'localhost'
            testServerPort: 8000
            testFile: '_SpecRunner.html'
            ignoreSloppyTests: false
            symbolSummaryTimeout: 20000
            serializeErrors: false
            allTestsTimeout: 30 * 60 * 1000
            printTitles: false

        options.browser = grunt.option('browser') || options.browser
        options.symbolSummaryTimeout = grunt.option('symbolSummaryTimeout') || options.symbolSummaryTimeout
        options.ignoreSloppyTests = grunt.option('ignoreSloppyTests') || options.ignoreSloppyTests
        options.serializeErrors = grunt.option('serializeErrors') || options.serializeErrors
        options.printTitles = grunt.option('printTitles') || options.printTitles

        if not fs.existsSync options.seleniumJar
            throw Error "The specified jar does not exist: #{options.seleniumJar}"

        done = @async()

        runTests(options).thenFinally (resultData) ->
            cleanUp resultData, done

    runTests = (options) ->
        if options.seleniumServerHost? and options.seleniumServerPort?
            server = "http://#{options.seleniumServerHost}:#{options.seleniumServerPort}/wd/hub"
            serverConnection server, options
        else
            localSeleniumServer options

    cleanUp = (resultData, done) ->
        resultData?.driver?.quit().then ->
            finish = ->
                if resultData.error then throw resultData.error else done(resultData.allTestsPassed)

            if resultData.server then resultData.server.stop().then(finish) else finish()

    localSeleniumServer = (options) ->
        server = new remote.SeleniumServer options.seleniumJar,
                        jvmArgs: options.seleniumServerJvmArgs
                        args: options.seleniumServerArgs

        server.start().then (serverAddress) ->
            grunt.log.writeln "Started webdriver server at #{serverAddress}"

            resolveResult = (resolveFn, resultData) ->
                resultData.server = server
                resolveFn.call result, resultData

            serverConnection(serverAddress, options).then (resultData) ->
                resolveResult result.fulfill, resultData
            .then null, (resultData) ->
                resolveResult result.reject, resultData

        result = webdriver.promise.defer()

    serverConnection = (serverAddress, options) ->
        testUrl = "http://#{options.testServer}:#{options.testServerPort}/#{options.testFile}"
        getWebServerUrl = (session)->
            "#{testUrl}?wdurl=#{encodeURIComponent(serverAddress)}&wdsid=#{session}&useWebdriver=true&ignoreSloppyTests=#{options.ignoreSloppyTests}"

        driver = new webdriver.Builder()
            .usingServer(serverAddress)
            .withCapabilities({'browserName': options.browser})
            .build()

        resultData = {}
        resultData.driver = driver unless grunt.option('keepalive')

        grunt.log.writeln "Connecting to webdriver server #{serverAddress}."
        grunt.log.writeln "Running Jasmine tests at #{testUrl} with #{options.browser}."

        resultData.allTestsPassed = false
        outputDots = 0
        outputPasses = 0
        outputFailures = 0

        driver.getSession().then (session) ->

            getAllTestResultsViaUnderscore = (outputDots) ->
                _.compact(
                    _.map(
                        _.pluck(
                            _.rest(document.querySelectorAll(".symbolSummary li"), outputDots),
                            'className'
                        ),
                        (status) ->
                            switch status
                                when 'passed' then '.'
                                when 'failed' then 'F'
                                else null
                    )
                ).join('')

            outputStatusUntilDoneWithUnderscore = (numTests, symbolSummaryElement) ->
                driver.executeScript(getAllTestResultsViaUnderscore, outputDots).then (results) ->
                    notYetOutput = results.length
                    isPendingPresent = (outputDots + notYetOutput) < numTests
                    dotsThreshold = if isPendingPresent then 100 else 0
                    outputStart = 0
                    while notYetOutput > dotsThreshold
                        toOutput = Math.min(notYetOutput, 100)
                        toOutputStr = results.slice(outputStart, outputStart + toOutput)
                        outputFailures += toOutputStr.split('F').length - 1

                        notYetOutput -= toOutput
                        outputDots += toOutput
                        outputStart += toOutput

                        grunt.log.writeln("#{toOutputStr} #{outputDots} / #{numTests} (#{outputFailures})")

                    isPendingPresent

            outputStatusUntilDoneWithoutUnderscore = (numTests, symbolSummaryElement) ->
                symbolSummaryElement.isElementPresent(webdriver.By.className('pending')).then (isPendingPresent) ->
                    webdriver.promise.fullyResolved(
                        [
                            driver.executeScript('return document.querySelectorAll(".symbolSummary .passed").length').then (passedElements) ->
                                pendingFailureDots = passedElements - outputPasses
                            driver.executeScript('return document.querySelectorAll(".symbolSummary .failed").length').then (failedElements) ->
                                pendingFailureDots = failedElements - outputFailures
                        ]
                    ).then ([pendingPasses, pendingFailures]) ->
                        dotsThreshold = if isPendingPresent then 100 else 0
                        while (pendingPasses + pendingFailures) > dotsThreshold
                            failuresToOutput = Math.min(pendingFailures, 100)
                            passesToOutput = Math.min(100 - failuresToOutput, pendingPasses)

                            pendingPasses -= passesToOutput
                            pendingFailures -= failuresToOutput
                            outputPasses += passesToOutput
                            outputFailures += failuresToOutput
                            outputDots = outputPasses + outputFailures

                            grunt.log.writeln("#{Array(failuresToOutput + 1).join('F')}#{Array(passesToOutput + 1).join('.')} #{outputDots} / #{numTests} (#{outputFailures})")

                        isPendingPresent


            runJasmineTests = webdriver.promise.createFlow (flow)->
                flow.execute ->
                    driver.get(getWebServerUrl(session.getId())).then ->
                        startTime = new Date()
                        lastTitle = ''
                        if options.printTitles
                          i = setInterval((=>
                              driver.getTitle()
                              .then (title) ->
                                title = title.substring(0, title.indexOf(' '))
                                if title != lastTitle
                                  lastTitle = title
                                  grunt.log.write "Running tests for '#{title}'"
                              .thenCatch (ex) ->
                                  #noop
                          ), 100)
                        # This section parses the jasmine so that the results can be written to the console.
                        driver.wait ->
                            driver.isElementPresent(webdriver.By.className('symbolSummary')).then (symbolSummaryFound)->
                                symbolSummaryFound
                        , options.symbolSummaryTimeout
                        driver.findElement(webdriver.By.className('symbolSummary')).then (symbolSummaryElement) ->
                            driver.executeScript('return {numTests: document.querySelectorAll(".symbolSummary li").length, underscore: !!window._}').then (summary) ->
                                numTests = summary.numTests
                                hasUnderscore = summary.underscore
                                grunt.log.writeln 'Test page loaded.  Running ' + "#{numTests}".cyan + ' tests...'
                                statusFn = (if hasUnderscore then outputStatusUntilDoneWithUnderscore else outputStatusUntilDoneWithoutUnderscore)
                                driver.wait ->
                                    statusFn(numTests, symbolSummaryElement).then (isPending) ->
                                        if isPending
                                            webdriver.promise.delayed(900).then -> !isPending
                                        else
                                            !isPending

                                , options.allTestsTimeout
                                driver.wait ->
                                    driver.isElementPresent(webdriver.By.id('details')).then (isPresent) ->
                                        isPresent
                                , 20000
                                driver.findElement(webdriver.By.id('details')).then (detailsElement) ->
                                    grunt.log.writeln "Done running all tests. Suite took #{(new Date() - startTime) / 1000} seconds."
                                    detailsElement.isElementPresent(webdriver.By.className('failed')).then (hasFailures) ->
                                        if (hasFailures)
                                            detailsElement.findElements(webdriver.By.className('failed')).then (failedElements) ->
                                                grunt.log.writeln "#{failedElements.length} of #{numTests} tests failed:".red
                                                webdriver.promise.fullyResolved(failedElement.getText() for failedElement in failedElements).then (failureTexts) ->
                                                    grunt.log.writeln (failureText.yellow for failureText in failureTexts).join("\n\n")
                                        else
                                            resultData.allTestsPassed = true
                                            grunt.log.writeln 'All ' + "#{numTests}".cyan + ' tests passed!'

            runJasmineTests.then ->
                result.fulfill resultData

        .then null, (err) ->
            grunt.log.writeln JSON.stringify('SerializedError:' + err, null, '\t') if err && options.serializeErrors
            resultData.error = err
            result.reject resultData

        result = webdriver.promise.defer()
