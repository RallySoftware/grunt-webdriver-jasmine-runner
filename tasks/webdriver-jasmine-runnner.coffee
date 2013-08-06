module.exports = (grunt) ->
    'use strict';

    fs = require 'fs';

    webdriver = require 'selenium-webdriver'
    remote = require 'selenium-webdriver/remote'

    grunt.registerMultiTask 'webdriver_jasmine_runner', 'Runs a jasmine test with webdriver.', ->
        options = @options
            seleniumJar: __dirname + '/lib/selenium-server-standalone-2.33.0.jar'
            seleniumServerPort: 4444
            seleniumServerArgs: []
            seleniumServerJvmArgs: []
            browser: 'chrome'
            testServer: 'localhost'
            testServerPort: 8000
            testFile: '_SpecRunner.html'
            ignoreSloppyTests: false
            allTestsTimeout: 30 * 60 * 1000

        options.browser = grunt.option('browser') || options.browser
        options.ignoreSloppyTests = grunt.option('ignoreSloppyTests') || options.ignoreSloppyTests

        if not fs.existsSync options.seleniumJar
            throw Error "The specified jar does not exist: #{options.seleniumJar}"

        done = @async()

        if options.seleniumServerHost? and options.seleniumServerPort?
            serverAddress = "http://#{options.seleniumServerHost}:#{options.seleniumServerPort}/wd/hub"
            serverConnection serverAddress, options, done
        else
            server = new remote.SeleniumServer
                jar: options.seleniumJar
                port: options.seleniumServerPort
                jvmArgs: options.seleniumServerJvmArgs
                args: options.seleniumServerArgs

            grunt.log.writeln "Starting webdriver server at http://localhost:#{options.seleniumServerPort}"
            server.start()
            server.address().then (serverAddress) ->
                serverConnection serverAddress, options, done


    serverConnection = (serverAddress, options, done) ->
        testUrl = "http://#{options.testServer}:#{options.testServerPort}/#{options.testFile}"
        getWebServerUrl = (session)->
            "#{testUrl}?wdurl=#{encodeURIComponent(serverAddress)}&wdsid=#{session}&useWebdriver=true&ignoreSloppyTests=#{options.ignoreSloppyTests}"

        driver = new webdriver.Builder()
            .usingServer(serverAddress)
            .withCapabilities({'browserName': options.browser})
            .build()

        grunt.log.writeln "Connecting to webdriver server at #{serverAddress}."
        grunt.log.writeln "Running Jasmine tests at #{testUrl} with #{options.browser}."

        allTestsPassed = false
        outputPasses = 0
        outputFailures = 0

        driver.session_.then (sessionData) ->
            runJasmineTests = webdriver.promise.createFlow (flow)->
                flow.execute ->
                    driver.get(getWebServerUrl(sessionData.id)).then ->
                        startTime = new Date()
                        # This section parses the jasmine so that the results can be written to the console.
                        driver.wait ->
                            driver.isElementPresent(webdriver.By.className('symbolSummary')).then (symbolSummaryFound)->
                                symbolSummaryFound
                        , 5000
                        driver.findElement(webdriver.By.className('symbolSummary')).then (symbolSummaryElement) ->
                            symbolSummaryElement.findElements(webdriver.By.tagName('li')).then (symbolSummaryIcons) ->
                                numTests = symbolSummaryIcons.length
                                grunt.log.writeln 'Test page loaded.  Running ' + "#{numTests}".cyan + ' tests...'
                                driver.wait ->
                                    symbolSummaryElement.isElementPresent(webdriver.By.className('pending')).then (isPendingPresent)->
                                        webdriver.promise.fullyResolved(
                                            [
                                                symbolSummaryElement.findElements(webdriver.By.className('passed')).then (failedElements) ->
                                                    pendingFailureDots = failedElements.length - outputPasses
                                                symbolSummaryElement.findElements(webdriver.By.className('failed')).then (failedElements) ->
                                                    pendingFailureDots = failedElements.length - outputFailures
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

                                            if isPendingPresent
                                                webdriver.promise.delayed(900).then -> !isPendingPresent
                                            else
                                                !isPendingPresent
                                , options.allTestsTimeout
                                driver.wait ->
                                    driver.isElementPresent(webdriver.By.id('details')).then (isPresent) ->
                                        isPresent
                                , 6000
                                driver.findElement(webdriver.By.id('details')).then (detailsElement) ->
                                    grunt.log.writeln "Done running all tests. Suite took #{(new Date() - startTime) / 1000} seconds."
                                    detailsElement.isElementPresent(webdriver.By.className('failed')).then (hasFailures) ->
                                        if (hasFailures)
                                            detailsElement.findElements(webdriver.By.className('failed')).then (failedElements) ->
                                                grunt.log.writeln "#{failedElements.length} of #{numTests} tests failed:".red
                                                webdriver.promise.fullyResolved(failedElement.getText() for failedElement in failedElements).then (failureTexts) ->
                                                    grunt.log.writeln (failureText.yellow for failureText in failureTexts).join("\n\n")
                                        else
                                            allTestsPassed = true
                                            grunt.log.writeln 'All ' + "#{numTests}".cyan + ' tests passed!'

            runJasmineTests.then ->
                if (!grunt.option('keepalive'))
                    grunt.log.writeln 'Closing test servers.'
                    driver.quit().addBoth ->
                        server?.stop()
                        done(allTestsPassed)
