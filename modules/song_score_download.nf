#!/usr/bin/env nextflow
nextflow.preview.dsl=2


process songScoreDownload {
    
    cpus params.cpus
    memory "${params.mem} MB"
 
    container 'icgc-argo/song-score'

    input:
        val analysisId

    output:
        tuple file('analysis.json'), file('./out/*') emit: files

    // doesn't exist yet, Roberto will make it happen
    // rob will make sing submit extract study from payload
    """
    export ACCESSTOKEN=${params.api_token}
    export METADATA_URL=${params.song_url}
    export STORAGE_URL=${params.score_url}

    sing configure --server-url ${params.song_url} --access-token ${params.api_token}
    sing get --analysisId ${analysisId} > analysis.json
    
    score-client download --analysisId ${analysisId} --output-dir ./out
    """
}
