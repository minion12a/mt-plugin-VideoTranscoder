package VideoTranscoder::Job;
use strict;
use base qw( MT::Object );

__PACKAGE__->install_properties(
    {
        column_defs => {
            id              => 'integer not null auto_increment',
            status          => 'smallint not null default 0',
            blog_id         => 'integer not null',
            name            => 'string(255)',
            asset_id        => 'integer not null',
            ets_pipeline_id => 'string(255) not null',
            ets_preset_id   => 'string(255) not null',
            ets_job_id      => 'string(255)',
            ets_job_status  => 'string(255)',
            ets_job_body    => 'text',
        },
        indexes     => {
            status          => 1,
            blog_id         => 1,
            ets_pipeline_id => 1,
            ets_preset_id   => 1,
            asset_id        => 1,
            created_by      => 1,
        },
        audit       => 1,
        datasource  => 'videotranscoder_job',
        primary_key => 'id',
    }
);

sub blog {
    my $job = shift;
    $job->cache_property(
        'blog',
        sub {
            require MT::Blog;
            MT::Blog->load( $job->blog_id );
        },
        @_
    );
}

sub asset {
    my $job = shift;
    $job->cache_property(
        'asset',
        sub {
            require MT::Asset;
            if ( $job->asset_id ) {
                return
                    scalar MT::Asset->load( $job->asset_id );
            }
        },
        @_
    );
}

sub _pipeline {
    my $job = shift;
    $job->cache_property(
        'pipeline',
        sub {
            require VideoTranscoder::AWS;
            my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
            my $pipeline = $ets->read_pipeline( $job->ets_pipeline_id );
            return $pipeline;
        },
        @_
    );
}

sub _preset {
    my $job = shift;
    $job->cache_property(
        'preset',
        sub {
            require VideoTranscoder::AWS;
            my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
            my $preset = $ets->read_preset( $job->ets_preset_id );
            return $preset;
        },
        @_
    );
}

sub _input_bucket {
    my $job = shift;
    $job->_pipeline ?
        $job->_pipeline()->{ InputBucket } :
        undef;
}

sub _output_bucket {
    my $job = shift;
    $job->_pipeline ? 
        $job->_pipeline()->{ OutputBucket } :
        undef;
}

sub input_key {
    my $job = shift;
    if ( $job->_pipeline && $job->asset ) {
        File::Spec->catfile( 'upload',
                             sprintf( '%d.%s',
                                      $job->id,
                                      $job->asset->file_ext ) );
    }
}

sub output_key {
    my $job = shift;
    if ( $job->_pipeline && $job->asset && $job->_preset ) {
        my $container = $job->_preset()->{ Container };
        File::Spec->catfile( 'encoded',
                             sprintf( '%d.%s',
                                      $job->id,
                                      $container ) );
    }
}

sub run {
    my $job = shift;
    if ( $job->status == 0 ) {
        $job->_create_ets_job();
    } elsif ( $job->status == 1 ) {
        $job->_check_ets_job();
    }
}

sub _create_ets_job {
    my $job = shift;
    if ( $job->_input_bucket && $job->input_key ) {
        require VideoTranscoder::AWS;
        my $upload = VideoTranscoder::AWS::S3->new( bucket_name => $job->_input_bucket );
        
        unless ( $upload->head_object( $job->input_key ) ) {
            require MT::FileMgr;
            my $fmgr = $job->blog->file_mgr || MT::FileMgr->new( 'Local' );
            my $bytes = $fmgr->get_data( $job->asset->file_path, 'upload' );
            $upload->put_object( $job->input_key, $bytes, $job->asset->mime_type );
            unless ( $upload->head_object( $job->input_key ) ) {
                die 'upload failed';
            }
        }
        my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
        my $ets_job = $ets->create_job( $job->input_key, $job->output_key, $job->ets_pipeline_id, $job->ets_preset_id );
        unless ( $ets_job ) {
            die 'create ElasticTranscoder job failed.';
        }
        $job->ets_job_id( $ets_job->{ Id } );
        $job->ets_job_status( $ets_job->{ Status } );
        require MT::Util;
        my $json = MT::Util::to_json( $ets_job );
        $job->ets_job_body( $json );
        $job->status( 1 );
        $job->save or die $job->errstr;
        return 1;
    }
    return 0;
}

sub _check_ets_job {
    my $job = shift;
    
    #require VideoTranscoder::AWS;
    #my $encoded = VideoTranscoder::AWS::S3->new( bucket_name => 'transcoder-test.takeyu-web.com' );
    #$encoded->get_object( 'encoded/sample-00001.png' );
    my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
    my $ets_job = $ets->read_job( $job->ets_job_id );
    unless ( $ets_job ) {
        die 'create ElasticTranscoder job failed.';
    }
    $job->ets_job_status( $ets_job->{ Status } );
    require MT::Util;
    my $json = MT::Util::to_json( $ets_job );
    $job->ets_job_body( $json );
    if ( $ets_job->{ Status } eq 'Complete' ) {
        $job->status( 2 );
        $job->_create_children();
    } elsif ( $ets_job->{ Status } eq 'Canceled' ) {
        $job->status( 3 );
    } elsif ( $ets_job->{ Status } eq 'Error' ) {
        $job->status( 4 );
    }
    $job->save or die $job->errstr;
    return 1;
}

sub _create_children {
    my $job = shift;
    require VideoTranscoder::AWS;
    my $encoded = VideoTranscoder::AWS::S3->new( bucket_name => $job->_output_bucket );
    my $data = $encoded->get_object( $job->output_key );
    unless ( $data ) {
        require MT::Log;
        my $log = MT::Log->new;
        $log->message( $encoded->errstr );
        $log->level( MT::Log::ERROR() );
        $log->save
            or die $log->errstr;
        return 0;
    }
    
    require File::Basename;
    my ( $basename, $dirname, $ext ) = File::Basename::fileparse( $job->asset->file_path, qr/\..*$/ );
    my $output_dir = File::Spec->catfile( $dirname, $basename );
    my $container = $job->_preset()->{ Container };
    my $output_ext = sprintf( '.%s', $container );
    my $output_name = sprintf( '%d%s', $job->id, $output_ext );
    
    # 書き込む際日本語ファイル名で書き込めないので内部文字列からUTF-8に
    require Encode;
    $output_dir = Encode::encode_utf8( $output_dir );
    $output_name = Encode::encode_utf8( $output_name );
    my $output_path = File::Spec->catfile( $output_dir, $output_name );
    my $fmgr = $job->blog->file_mgr || MT::FileMgr->new( 'Local' );
    $fmgr->mkpath( $output_dir ) or die $fmgr->errstr;
    $fmgr->put_data( $data, $output_path ) or die $fmgr->errstr;
    
    # 内部文字列に戻す
    $output_dir = Encode::decode_utf8( $output_dir );
    $output_name = Encode::decode_utf8( $output_name );
    $output_path = Encode::decode_utf8( $output_path );
    
    require MT::Util;
    my $asset = MT->model( 'video' )->new;
    $asset->blog_id( $job->asset->blog_id );
    $asset->label( $job->asset->label );
    
    my $site_path = $job->blog->site_path;
    my $rel_path = File::Spec->abs2rel($output_path, $site_path );
    $rel_path =~ s/\\/\//;
    my @rel_path_parts = map{ MT::Util::encode_url( $_ ) } split '/', $rel_path;
    $asset->url( '%r/' . join( '/', @rel_path_parts ) );
    $asset->file_path( '%r/' . $rel_path );
    
    $asset->description( $job->asset->description );
    $asset->file_name( $output_name );
    $asset->file_ext( $output_ext );
    $asset->mime_type( 'video/' . $container );
    $asset->parent( $job->asset_id );
    $asset->created_by( $job->created_by );
    require MT::Util;
    $asset->created_on( MT::Util::epoch2ts( $job->blog, time ) );
    $asset->save or die $asset->errstr;
}

1;