function Build-Body {
    [CmdletBinding()]
    param(
        [object] $Format,
        [object] $Inputs
    )
    process {
        $Inputs.GetEnumerator().Where({ $Format.Body.Values -match $_.Key }).foreach{
            $Field = ($_.Key).ToLower()
            $Value = $_.Value
            if ($Field -eq 'body') {
                # Add 'body' value as [System.Net.Http.ByteArrayContent]
                $FullFilePath = $Script:Falcon.Api.Path($_.Value)
                Write-Verbose "[Build-Body] Content: $FullFilePath)"
                $ByteStream = if ($PSVersionTable.PSVersion.Major -ge 6) {
                    Get-Content $FullFilePath -AsByteStream
                } else {
                    Get-Content $FullFilePath -Encoding Byte -Raw
                }
                $ByteArray = [System.Net.Http.ByteArrayContent]::New($ByteStream)
                $ByteArray.Headers.Add('Content-Type', $Headers.ContentType)
            } else {
                if (!$Body) {
                    $Body = @{}
                }
                if ($Value | Get-Member -MemberType Method | Where-Object { $_.Name -eq 'Normalize' }) {
                    # Normalize values to avoid Json conversion errors
                    if ($Value -is [array]) {
                        $Value = [array] ($Value).Normalize()
                    } else {
                        $Value = ($Value).Normalize()
                    }
                }
                $Format.Body.GetEnumerator().Where({ $_.Value -eq $Field }).foreach{
                    if ($_.Key -eq 'root') {
                        # Add key/value pair directly to 'Body'
                        $Body.Add($Field, $Value)
                    } else {
                        # Create parent object and add key/value pair
                        if (!$Parents) {
                            $Parents = @{}
                        }
                        if (!$Parents.($_.Key)) {
                            $Parents[$_.Key] = @{}
                        }
                        $Parents.($_.Key).Add($Field, $Value)
                    }
                }
            }
        }
        if ($ByteArray) {
            # Output ByteArray content
            $ByteArray
        } elseif ($Parents) {
            $Parents.GetEnumerator().foreach{
                # Add parents as arrays in output
                $Body[$_.Key] = @( $_.Value )
            }
        }
    }
    end {
        if (($Body.Keys | Measure-Object).Count -gt 0) {
            # Output 'Body' result
            Write-Verbose "[Build-Body]`n$(ConvertTo-Json -InputObject $Body -Depth 8)"
            $Body
        }
    }
}
function Build-Formdata {
    [CmdletBinding()]
    param(
        [object] $Format,
        [object] $Inputs
    )
    process {
        $Inputs.GetEnumerator().Where({ $Format.Formdata.Values -match "^$($_.Key)$" }).foreach{
            if (!$Formdata) {
                $Formdata = @{}
            }
            $Formdata[$_.Key] = if ($_.Key -eq 'content') {
                # Collect file content as a string
                [string] (Get-Content ($Script:Falcon.Api.Path($_.Value)) -Raw)
            } else {
                $_.Value
            }
        }
    }
    end {
        if (($Formdata.Keys | Measure-Object).Count -gt 0) {
            # Output 'Formdata' result
            Write-Verbose "[Build-Formdata]`n$(ConvertTo-Json -InputObject $Formdata -Depth 8)"
            $Formdata
        }
    }
}
function Build-Param {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [string] $Endpoint,
        [object] $Headers,
        [object] $Format,
        [object] $Inputs,
        [int] $Max
    )
    begin {
        if (!$Max) {
            # Set max number of items to 500 if not specified
            $Max = 500
        }
        # Set baseline request parameters
        $Base = @{
            Path = "$($Script:Falcon.Hostname)$($Endpoint.Split(':')[0])"
            Method = $Endpoint.Split(':')[1]
            Headers = $Headers
        }
        $Switches = @{}
        $Inputs.GetEnumerator().Where({ $_.Key -match '^(Total|All|Detailed)$' }).foreach{
            $Switches.Add($_.Key, $_.Value)
        }
    }
    process {
        @('Body', 'Formdata', 'Query').foreach{
            # Create key/value pairs for each "Build-<Input>" function
            if (!$Content) {
                $Content = @{}
            }
            if ($Format.$_) {
                $Value = & "Build-$_" -Format $Format -Inputs $Inputs
                if ($Value) {
                    $Content.Add($_, $Value)
                }
            }
        }
        if ($Format.Outfile) {
            $Inputs.GetEnumerator().Where({ $Format.Outfile -eq $_.Key }).foreach{
                # Convert 'Outfile' to absolute path
                $Outfile = $Script:Falcon.Api.Path($_.Value)
                $Content.Add('Outfile', $Outfile)
            }
        }
        if ($Content.Query -and ($Content.Query | Measure-Object).Count -gt $Max) {
            for ($i = 0; $i -lt ($Content.Query | Measure-Object).Count; $i += $Max) {
                # Split 'Query' values into groups
                $Split = $Switches.Clone()
                $Split.Add('Endpoint', $Base.Clone())
                $Split.Endpoint.Path += "?$($Content.Query[$i..($i + ($Max - 1))] -join '&')"
                $Content.GetEnumerator().Where({ $_.Key -ne 'Query' -and $_.Value }).foreach{
                    # Add 'Body' values
                    if ($_.Key -eq 'Body' -and $Split.Endpoint.Headers.ContentType -eq 'application/json') {
                        $_.Value = ConvertTo-Json -InputObject $_.Value -Depth 8
                    }
                    # Add 'Formdata' values
                    $Split.Endpoint.Add($_.Key, $_.Value)
                }
                ,$Split
            }
        } elseif ($Content.Body -and ($Content.Body.ids | Measure-Object).Count -gt $Max) {
            for ($i = 0; $i -lt ($Content.Body.ids | Measure-Object).Count; $i += $Max) {
                # Split 'Body' content into groups using 'ids'
                $Split = $Switches.Clone()
                $Split.Add('Endpoint', $Base.Clone())
                $Split.Add('Body', @{ ids = $Content.Body.ids[$i..($i + ($Max - 1))] })
                $Content.GetEnumerator().Where({ $_.Value }).foreach{
                    if ($_.Key -eq 'Query') {
                        # Add 'Query' values
                        $Split.Endpoint.Path += "?$($_.Value -join '&')"
                    } elseif ($_.Key -eq 'Body') {
                        # Add other 'Body' values
                        ($_.Value).GetEnumerator().Where({ $_.Key -ne 'ids' }).foreach{
                            $Split.Endpoint.Body.Add($_.Key, $_.Value)
                        }
                    } else {
                        # Add 'Formdata' values
                        $Split.Endpoint.Add($_.Key, $_.Value)
                    }
                }
                if ($Split.Endpoint.Headers.ContentType -eq 'application/json') {
                    # Convert body to Json
                    $Split.Body = ConvertTo-Json -InputObject $Split.Body -Depth 8
                }
                ,$Split
            }
        } else {
            # Use base parameters, add content and output single parameter set
            $Switches.Add('Endpoint', $Base.Clone())
            if ($Content) {
                $Content.GetEnumerator().foreach{
                    if ($_.Key -eq 'Query') {
                        $Switches.Endpoint.Path += "?$($_.Value -join '&')"
                    } else {
                        if ($_.Key -eq 'Body' -and $Switches.Endpoint.Headers.ContentType -eq 'application/json') {
                            $_.Value = ConvertTo-Json -InputObject $_.Value -Depth 8
                        }
                        $Switches.Endpoint.Add($_.Key, $_.Value)
                    }
                }
            }
            $Switches
        }
    }
}
function Build-Query {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [object] $Format,
        [object] $Inputs
    )
    process {
        $Inputs.GetEnumerator().Where({ $Format.Query -contains $_.Key }).foreach{
            $Field = ($_.Key).ToLower()
            ($_.Value).foreach{
                # Output array of strings to append to 'Path' and HTML-encode '+'
                ,"$($Field)=$($_ -replace '\+','%2B')"
            }
        }
    }
}
function Invoke-Falcon {
    [CmdletBinding()]
    param(
        [string] $Command,
        [string] $Endpoint,
        [object] $Headers,
        [object] $Inputs,
        [object] $Format,
        [int] $Max
    )
    begin {
        # Gather parameters for Build-Param
        $BuildParam = @{}
        $PSBoundParameters.GetEnumerator().Where({ $_.Key -ne 'Command' }).foreach{
            $BuildParam.Add($_.Key, $_.Value)
        }
        # Add 'Accept' when not present
        if (!$BuildParam.Headers) {
            $BuildParam.Add('Headers', @{})
        }
        if (!$BuildParam.Headers.Accept) {
            $BuildParam.Headers.Add('Accept', 'application/json')
        }
        if ($Inputs.All -eq $true -and !$Inputs.Limit) {
            # Add maximum 'Limit' when not present and using 'All'
            $Limit = (Get-Command $Command).ParameterSets.Where({
                $_.Name -eq $Endpoint }).Parameters.Where({ $_.Name -eq 'Limit' }).Attributes.MaxRange
            if ($Limit) {
                $Inputs.Add('Limit', $Limit)
                Write-Verbose "[Invoke-Falcon] Limit: $Limit"
            }
        }
    }
    process {
        foreach ($Item in (Build-Param @BuildParam)) {
            if (!$Script:Falcon.Api.Client.DefaultRequestHeaders.Authorization -or
            ($Script:Falcon.Expiration -le (Get-Date).AddSeconds(15))) {
                # Verify authorization token
                Request-FalconToken
            }
            $Request = $Script:Falcon.Api.Invoke($Item.Endpoint)
            if ($Item.Endpoint.Outfile) {
                if (Test-Path $Item.Endpoint.Outfile) {
                    # Display 'Outfile'
                    Get-ChildItem $Item.Endpoint.Outfile
                }
            } elseif ($Request.Result.Content) {
                # Capture pagination for 'Total' and 'All'
                $Pagination = (ConvertFrom-Json (
                    $Request.Result.Content).ReadAsStringAsync().Result).meta.pagination
                if ($Pagination -and $Item.Total -eq $true) {
                    # Output 'Total'
                    $Pagination.total
                } else {
                    $Result = Write-Result $Request
                    if ($Result -and $Item.Detailed -eq $true -and $Item.Endpoint.Path -notmatch '/combined/') {
                        # Output 'Detailed'
                        & $Command -Ids $Result
                    } elseif ($Result) {
                        # Output result
                        $Result
                    }
                    if ($Pagination -and $Item.All -eq $true) {
                        # Repeat requests until 'meta.pagination.total' is reached
                        $Param = @{
                            Request = $Request
                            Result = $Result
                            Pagination = $Pagination
                            Item = $Item
                        }
                        Invoke-Loop @Param
                    }
                }
            }
        }
    }
}
function Invoke-Loop {
    [CmdletBinding()]
    param(
        [object] $Request,
        [object] $Result,
        [object] $Pagination,
        [object] $Item
    )
    process {
        for ($i = ($Result | Measure-Object).Count; $Pagination.next_page -or $i -lt $Pagination.total;
        $i += ($Result | Measure-Object).Count) {
            # Clone endpoint parameters, capture pagination
            $Clone = $Item.Clone()
            $Clone.Endpoint = $Item.Endpoint.Clone()
            $Page = if ($Pagination.after) {
                @('after', $Pagination.after)
            } elseif ($Pagination.next_page) {
                @('offset', $Pagination.offset)
            } elseif ($Pagination.offset -match '^\d{1,}$') {
                @('offset', $i)
            } else {
                @('offset', $Pagination.offset)
            }
            $Clone.Endpoint.Path = if ($Clone.Endpoint.Path -match "$($Page[0])=\d{1,}") {
                # If offset was input, continue from that value
                $Current = [regex]::Match(
                    $Clone.Endpoint.Path, 'offset=(\d+)(^&)?').Captures.Value
                $Page[1] += [int] $Current.Split('=')[-1]
                $Clone.Endpoint.Path -replace $Current, ($Page -join '=')
            } elseif ($Clone.Endpoint.Path -match "$Endpoint^") {
                # Add pagination
                "$($Clone.Endpoint.Path)?$($Page -join '=')"
            } else {
                "$($Clone.Endpoint.Path)&$($Page -join '=')"
            }
            # Make request, update pagination and output result
            $Request = $Script:Falcon.Api.Invoke($Clone.Endpoint)
            if ($Request.Result.Content) {
                $Pagination = (ConvertFrom-Json (
                    $Request.Result.Content).ReadAsStringAsync().Result).meta.pagination
                $Result = Write-Result $Request
                Write-Verbose "[Invoke-Loop] $i of $($Pagination.Total)"
                if ($Result -and $Clone.Detailed -eq $true -and $Clone.Endpoint.Path -notmatch
                '/combined/') {
                    & $Command -Ids $Result
                } elseif ($Result) {
                    $Result
                }
            }
        }
    }
}
function Write-Result {
    [CmdletBinding()]
    param (
        [object] $Request
    )
    begin {
        $Verbose = if ($Request.Result.Headers) {
            # Capture response header for verbose output
            ($Request.Result.Headers.GetEnumerator().foreach{
                ,"$($_.Key)=$($_.Value)"
            })
        }
    }
    process {
        if ($Request.Result.Content -match '^<') {
            # Output HTML response as a string
            $HTML = ($Response.Result.Content).ReadAsStringAsync().Result
        } elseif ($Request.Result.Content) {
            # Convert Json response
            $Json = ConvertFrom-Json ($Request.Result.Content).ReadAsStringAsync().Result
            $Verbose += if ($Json.meta) {
                ($Json.meta.PSObject.Properties).foreach{
                    $Parent = 'meta'
                    if ($_.Value -is [PSCustomObject]) {
                        $Parent += ".$($_.Name)"
                        ($_.Value.PSObject.Properties).foreach{
                            ,"$($Parent).$($_.Name)=$($_.Value)"
                        }
                    } elseif ($_.Name -ne 'trace_id') {
                        ,"$($Parent).$($_.Name)=$($_.Value)"
                    }
                }
            }
        }
        if ($Verbose) {
            # Output verbose response header
            Write-Verbose "[Write-Result] $($Verbose -join ', ')"
        }
        if ($HTML) {
            $HTML
        } elseif ($Json) {
            $Content = ($Json.PSObject.Properties).Where({ @('meta', 'errors') -notcontains $_.Name -and
            $_.Value }).foreach{
                # Gather populated fields from object
                $_.Name
            }
            if ($Content) {
                Write-Verbose "[Write-Result] $($Content -join ', ')"
                if (($Content | Measure-Object).Count -eq 1) {
                    if ($Content[0] -eq 'combined') {
                        # Output 'combined.resources'
                        ($Json.combined.resources).PSObject.Properties.Value
                    } else {
                        # Output single field
                        $Json.($Content[0])
                    }
                } elseif (($Content | Measure-Object).Count -gt 1) {
                    # Output all fields
                    $Json
                }
            }
            ($Json.errors).Where({ $_.Values }).foreach{
                # TODO Test error output and clean up
                Write-Verbose "[Write-Result] Errors:`n$(ConvertTo-Json -InputObject $_.Values -Depth 8)"
                ($_.Values).foreach{
                    $PSCmdlet.WriteError(
                        [System.Management.Automation.ErrorRecord]::New(
                            [Exception]::New("$($_.code): $($_.message)"),
                            $Json.meta.trace_id,
                            [System.Management.Automation.ErrorCategory]::NotSpecified,
                            $Request
                        )
                    )
                }
            }
        }
        # Check for rate limiting
        Wait-RetryAfter $Request
    }
}
function Wait-RetryAfter {
    [CmdletBinding()]
    param(
        [object] $Request
    )
    process {
        if ($Script:Falcon.Api.LastCode -eq 429 -and $Request.Result.RequestMessage.RequestUri.AbsolutePath -ne
        '/oauth2/token') {
            # Convert 'X-Ratelimit-Retryafter' value to seconds and wait
            $Wait = [System.DateTimeOffset]::FromUnixTimeSeconds(($Request.Result.Headers.GetEnumerator().Where({
                $_.Key -eq 'X-Ratelimit-Retryafter' }).Value)).Second
            Write-Verbose "[Wait-RetryAfter] Rate limited for $Wait seconds..."
            Start-Sleep -Seconds $Wait
        }
    }
}